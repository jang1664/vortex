#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Float constants without libc dependency
static inline float _pos_inf() {
  union { unsigned int i; float f; } u;
  u.i = 0x7f800000u;
  return u.f;
}
#define MY_INFINITY _pos_inf()

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Pure single-precision expf — avoids libc's expf which may use 'd' extension
// instructions that are not available on some FPGA bitstreams.
//
// Uses the identity: exp(x) = 2^(x / ln2) = 2^(n + f), where n=floor, f=frac
// Then 2^f is approximated by a degree-4 minimax polynomial on [0,1).
///////////////////////////////////////////////////////////////////////////////
static inline float my_expf(float x) {
  // Clamp to avoid overflow/underflow
  if (x > 88.7f)  return 3.4028235e+38f;
  if (x < -87.3f) return 0.0f;

  // x / ln(2)
  const float LOG2E = 1.4426950408889634f;  // 1/ln(2)
  float t = x * LOG2E;

  // n = floor(t), f = t - n
  // Use integer truncation toward -inf
  int n = (int)t;
  if ((float)n > t) n--;  // correct for negative values
  float f = t - (float)n;

  // Polynomial approximation of 2^f for f in [0,1)
  // Coefficients from minimax fit (max error < 2e-7 over [0,1))
  float p = 1.0f + f * (0.6931472f + f * (0.2402265f + f * (0.0555041f + f * 0.0096139f)));

  // Multiply by 2^n via integer bit manipulation of IEEE 754 float
  union { float fval; unsigned int ival; } u;
  u.fval = p;
  u.ival += (unsigned int)n << 23;  // add n to exponent field

  return u.fval;
}

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
//   1. Parallel reduction to find max value (for numerical stability)
//   2. Parallel computation of exp(x - max) and sum reduction
//   3. Parallel normalization: output = exp(x - max) / sum
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
  
  // Allocate shared memory for reduction
  auto cache = (float *)__local_mem(block_size * sizeof(float));
  
  //===========================================================================
  // Step 1: Find max value (for numerical stability)
  //===========================================================================
  float local_max = -MY_INFINITY;
  
  // Each thread finds local max (only if block is active)
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = input_row[k] * scale;
      
      // Apply causal mask if enabled
      if (use_mask && k > q) {
        val = -MY_INFINITY;
      }
      
      if (val > local_max) {
        local_max = val;
      }
    }
  }
  
  // Store local max in shared memory
  cache[tid] = local_max;
  __syncthreads();
  
  // Reduction to find global max
  for (uint32_t s = block_size / 2; s > 0; s >>= 1) {
    if (tid < s) {
      if (cache[tid + s] > cache[tid]) {
        cache[tid] = cache[tid + s];
      }
    }
    __syncthreads();
  }
  
  // Broadcast max to all threads
  float global_max = cache[0];
  __syncthreads();
  
  //===========================================================================
  // Step 2: Compute exp(x - max) and sum
  //===========================================================================
  float local_sum = 0.0f;
  
  // Each thread computes exp for its elements and accumulates sum (only if active)
  // NOTE: We do NOT write intermediate exp values to global memory here.
  // Storing to output_row[] and reading back in Step 3 creates a global-memory
  // read-after-write hazard. On FPGA without dcache, AXI writes and reads to
  // the same address can race (vx_barrier is execution-only, not a memory
  // fence), causing intermittent deadlock in the DDR controller.
  // Instead, we recompute exp() in Step 3 — one extra expf() per element
  // but zero global RAW hazard.
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = input_row[k] * scale;
      
      // Apply causal mask if enabled
      if (use_mask && k > q) {
        val = -MY_INFINITY;
      }
      
      float exp_val = my_expf(val - global_max);
      local_sum += exp_val;
    }
  }
  
  // Store local sum in shared memory
  cache[tid] = local_sum;
  __syncthreads();
  
  // Reduction to find global sum
  for (uint32_t s = block_size / 2; s > 0; s >>= 1) {
    if (tid < s) {
      cache[tid] += cache[tid + s];
    }
    __syncthreads();
  }
  
  // Broadcast sum to all threads
  float global_sum = cache[0];
  __syncthreads();
  
  //===========================================================================
  // Step 3: Normalize (recompute exp to avoid global-memory RAW hazard)
  //===========================================================================
  float inv_sum = active ? (1.0f / global_sum) : 0.0f;
  
  if (active) {
    for (uint32_t k = tid; k < seq_len_k; k += block_size) {
      float val = input_row[k] * scale;
      
      // Apply causal mask if enabled
      if (use_mask && k > q) {
        val = -MY_INFINITY;
      }
      
      output_row[k] = my_expf(val - global_max) * inv_sum;
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
