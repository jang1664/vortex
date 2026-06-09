#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Softmax Kernel for Attention
// 
// Formula: softmax(x) = exp(x - max(x)) / sum(exp(x - max(x)))
// 
// Input: [batch, num_heads, seq_len_q, seq_len_k]
// Output: [batch, num_heads, seq_len_q, seq_len_k]
// 
// Each thread block processes one row (softmax over seq_len_k dimension)
// Strategy:
//   1. Stage the scaled input row in local memory
//   2. Parallel reduction to find max value (for numerical stability)
//   3. Compute exp(x - max) once, cache it locally, and reduce the sum
//   4. Normalize from the cached exp values and store output
///////////////////////////////////////////////////////////////////////////////

void kernel_softmax(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  auto pMask = reinterpret_cast<data_t *>(arg->mask_addr);
  
  uint32_t batch_size = arg->batch_size;
  uint32_t num_heads = arg->num_heads;
  uint32_t seq_len_q = arg->seq_len_q;
  uint32_t seq_len_k = arg->seq_len_k;
  uint32_t use_mask = arg->use_mask;
  float scale = arg->scale;
  
  // Each block handles one row: (batch_idx, head_idx, q_idx)
  uint32_t rows_total = batch_size * num_heads * seq_len_q;
  uint32_t row_idx = blockIdx.x;
  
  // Check if this block has work to do
  bool active = (row_idx < rows_total);
  
  // Decode row index (even for inactive blocks, to avoid divergence issues)
  uint32_t b = active ? row_idx / (num_heads * seq_len_q) : 0;
  uint32_t remainder = active ? row_idx % (num_heads * seq_len_q) : 0;
  uint32_t h = active ? remainder / seq_len_q : 0;
  uint32_t q = active ? remainder % seq_len_q : 0;
  
  // Base pointer for this row
  uint32_t row_offset = ((b * num_heads + h) * seq_len_q + q) * seq_len_k;
  data_t *input_row = pInput + row_offset;
  data_t *output_row = pOutput + row_offset;
  
  uint32_t tid = threadIdx.x;
  uint32_t block_size = blockDim.x;
  
  uint32_t input_offset = 0;
  uint32_t exp_offset = input_offset + seq_len_k * sizeof(float);
  uint32_t reduce_offset = exp_offset + seq_len_k * sizeof(float);
  uint32_t local_bytes = reduce_offset + block_size * sizeof(float);

  auto local_base = (uint8_t *)__local_mem(local_bytes);
  auto input_cache = (float *)(local_base + input_offset);
  auto exp_cache = (float *)(local_base + exp_offset);
  auto reduce_cache = (float *)(local_base + reduce_offset);

  //===========================================================================
  // Step 0: Stage input row in local memory
  //===========================================================================
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = fp16_to_float(input_row[k]) * scale;
      input_cache[k] = (use_mask && k > q) ? VX_NEG_INF : val;
    }
  }
  __syncthreads();
  
  //===========================================================================
  // Step 1: Find max value (for numerical stability)
  //===========================================================================
  float local_max = VX_NEG_INF;
  
  // Each thread finds local max (only if block is active)
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = input_cache[k];
      
      if (val > local_max) {
        local_max = val;
      }
    }
  }
  
  // Store local max in shared memory
  reduce_cache[tid] = local_max;
  __syncthreads();
  
  // Reduction to find global max
  for (uint32_t s = block_size / 2; s > 0; s >>= 1) {
    if (tid < s) {
      if (reduce_cache[tid + s] > reduce_cache[tid]) {
        reduce_cache[tid] = reduce_cache[tid + s];
      }
    }
    __syncthreads();
  }
  
  // Broadcast max to all threads
  float global_max = reduce_cache[0];
  __syncthreads();
  
  //===========================================================================
  // Step 2: Compute exp(x - max) once and sum
  //===========================================================================
  float local_sum = 0.0f;
  
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = input_cache[k];
      float exp_val = 0.0f;
      
      if (val != VX_NEG_INF) {
        exp_val = vx_expf(val - global_max);
      }
      
      exp_cache[k] = exp_val;
      local_sum += exp_val;
    }
  }
  
  // Store local sum in shared memory
  reduce_cache[tid] = local_sum;
  __syncthreads();
  
  // Reduction to find global sum
  for (uint32_t s = block_size / 2; s > 0; s >>= 1) {
    if (tid < s) {
      reduce_cache[tid] += reduce_cache[tid + s];
    }
    __syncthreads();
  }
  
  // Broadcast sum to all threads
  float global_sum = reduce_cache[0];
  __syncthreads();
  
  //===========================================================================
  // Step 3: Normalize using cached exp values
  //===========================================================================
  float inv_sum = active ? (1.0f / global_sum) : 0.0f;
  
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      output_row[k] = float_to_fp16(exp_cache[k] * inv_sum);
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SOFTMAX:
      kernel_softmax(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
}
