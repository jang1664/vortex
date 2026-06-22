#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <math.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// RMSNorm Kernel
// Formula: output = input * rsqrt(mean(input^2) + eps) * gamma
//
// Strategy:
// Use shared memory reduction similar to dotproduct example
///////////////////////////////////////////////////////////////////////////////

void kernel_rmsnorm(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  auto pGamma = reinterpret_cast<data_t *>(arg->gamma_addr);
  
  uint32_t batch_size = arg->batch_size;
  uint32_t seq_len = arg->seq_len;
  uint32_t hidden_dim = arg->hidden_dim;
  float eps = arg->eps;
  
  // Thread indices
  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  int cache_idx = threadIdx.x;
  
  // Each block processes one token (one row)
  uint32_t token_idx = blockIdx.x;
  
  if (token_idx >= batch_size * seq_len) return;
  
  // Pointer to this token's data
  auto pInputRow = pInput + token_idx * hidden_dim;
  auto pOutputRow = pOutput + token_idx * hidden_dim;
  
  // Allocate shared memory for reduction
  auto cache = reinterpret_cast<float*>(__local_mem(blockDim.x * sizeof(float)));
  
  // Phase 1: Compute sum of squares with reduction
  float sum_sq = 0.0f;
  
  // Each thread accumulates its portion
  for (uint32_t i = cache_idx; i < hidden_dim; i += blockDim.x) {
    float val = fp16_to_float(pInputRow[i]);
    sum_sq += val * val;
  }
  
  // Store in shared memory
  cache[cache_idx] = sum_sq;
  __syncthreads();
  
  // Reduction in shared memory (similar to dotproduct)
  int i = blockDim.x / 2;
  while (i != 0) {
    if (cache_idx < i) {
      cache[cache_idx] += cache[cache_idx + i];
    }
    __syncthreads();
    i /= 2;
  }
  
  // Thread 0 has the final sum, broadcast to all
  __syncthreads();
  sum_sq = cache[0];
  
  // Compute RMS normalization factor
  float mean_sq = sum_sq / hidden_dim;
  float rms_norm = 1.0f / sqrtf(mean_sq + eps);
  
  // Phase 2: Normalize and apply gamma
  for (uint32_t i = cache_idx; i < hidden_dim; i += blockDim.x) {
    float val = fp16_to_float(pInputRow[i]);
    float gamma = fp16_to_float(pGamma[i]);
    pOutputRow[i] = float_to_fp16(val * rms_norm * gamma);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_RMSNORM:
      kernel_rmsnorm(arg);
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
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
}
