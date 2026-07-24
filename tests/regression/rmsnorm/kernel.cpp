#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <math.h>

// Type aliases
using data_t = fp16_t;

#ifdef RMSNORM_USE_ADAPTIVE_REDUCTION
#define RMSNORM_HELPER static inline __attribute__((always_inline))

RMSNORM_HELPER uint32_t float_to_bits(float value) {
  union { float f; uint32_t u; } v;
  v.f = value;
  return v.u;
}

RMSNORM_HELPER float bits_to_float(uint32_t value) {
  union { uint32_t u; float f; } v;
  v.u = value;
  return v.f;
}

RMSNORM_HELPER float shfl_down_float(float value, uint32_t offset) {
  return bits_to_float((uint32_t)vx_shfl_down(
      float_to_bits(value), offset, NUM_THREADS - 1, 0));
}

RMSNORM_HELPER float shfl_idx_float(float value, uint32_t index) {
  return bits_to_float((uint32_t)vx_shfl_idx(
      float_to_bits(value), index, NUM_THREADS - 1, 0));
}

RMSNORM_HELPER float warp_rms(float sum_sq, uint32_t lane,
                              uint32_t hidden_dim, float eps) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(sum_sq, offset);
    if (lane + offset < NUM_THREADS) {
      sum_sq += other;
    }
  }

  float rms_norm = 0.0f;
  if (lane == 0) {
    rms_norm = 1.0f / sqrtf(sum_sq / (float)hidden_dim + eps);
  }
  return shfl_idx_float(rms_norm, 0);
}
#else
#define RMSNORM_HELPER static inline
#endif

RMSNORM_HELPER float reduce_rms(float sum_sq, uint32_t lane,
                                uint32_t block_size, uint32_t hidden_dim,
                                float eps) {
#ifdef RMSNORM_USE_ADAPTIVE_REDUCTION
  if (block_size == NUM_THREADS) {
    return warp_rms(sum_sq, lane, hidden_dim, eps);
  }
#endif

  auto cache =
      reinterpret_cast<float *>(__local_mem(block_size * sizeof(float)));
  cache[lane] = sum_sq;
  __syncthreads();

  for (uint32_t offset = block_size >> 1; offset > 0; offset >>= 1) {
    if (lane < offset) {
      cache[lane] += cache[lane + offset];
    }
    __syncthreads();
  }
  return 1.0f / sqrtf(cache[0] / (float)hidden_dim + eps);
}

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
  
  const uint32_t lane = threadIdx.x;
  const uint32_t block_size = blockDim.x;
  
  // Each block processes one token (one row)
  uint32_t token_idx = blockIdx.x;
  
  if (token_idx >= batch_size * seq_len) return;
  
  // Pointer to this token's data
  auto pInputRow = pInput + token_idx * hidden_dim;
  auto pOutputRow = pOutput + token_idx * hidden_dim;
  
  // Phase 1: Compute sum of squares with reduction
  float sum_sq = 0.0f;
  
  // Each thread accumulates its portion
  for (uint32_t i = lane; i < hidden_dim; i += block_size) {
    float val = fp16_to_float(pInputRow[i]);
    sum_sq += val * val;
  }

  const float rms_norm =
      reduce_rms(sum_sq, lane, block_size, hidden_dim, eps);
  
  // Phase 2: Normalize and apply gamma
  for (uint32_t i = lane; i < hidden_dim; i += block_size) {
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
static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
