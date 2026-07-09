#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <cmath>

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Element-wise Operations with Scalar
// 
// Supports: pow_scalar, mul_scalar, add_scalar
// 
// Critical for transformers:
// - pow(x, 2): RMSNorm variance computation (x^2)
// - mul_scalar: Scaling operations
// - add_scalar: Bias addition, epsilon addition
///////////////////////////////////////////////////////////////////////////////

void kernel_pow_scalar(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  float exponent = arg->scalar;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  // Special case optimization for common exponents
  if (exponent == 2.0f) {
    for (uint32_t i = thread_id; i < size; i += total_threads) {
      float val = pInput[i];
      pOutput[i] = val * val;
    }
  } else if (exponent == 0.5f) {
    for (uint32_t i = thread_id; i < size; i += total_threads) {
      pOutput[i] = sqrtf(pInput[i]);
    }
  } else {
    for (uint32_t i = thread_id; i < size; i += total_threads) {
      pOutput[i] = powf(pInput[i], exponent);
    }
  }
}

void kernel_mul_scalar(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  float scalar = arg->scalar;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = pInput[i] * scalar;
  }
}

void kernel_add_scalar(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  float scalar = arg->scalar;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = pInput[i] + scalar;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_POW_SCALAR: kernel_pow_scalar(arg); break;
    case KERNEL_MUL_SCALAR: kernel_mul_scalar(arg); break;
    case KERNEL_ADD_SCALAR: kernel_add_scalar(arg); break;
    default: break;
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
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
