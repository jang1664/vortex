#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Element-wise Unary Operations Kernel
// 
// Supports: rsqrt, sin, cos, exp, log, neg, abs, sqrt
// 
// Critical for transformers:
// - rsqrt: RMSNorm (1/sqrt(x))
// - sin/cos: Rotary Position Embedding (RoPE)
// - exp: Softmax computation
///////////////////////////////////////////////////////////////////////////////

void kernel_rsqrt(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = 1.0f / vx_sqrtf(pInput[i]);
  }
}

void kernel_sin(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_sinf(pInput[i]);
  }
}

void kernel_cos(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_cosf(pInput[i]);
  }
}

void kernel_exp(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_expf(pInput[i]);
  }
}

void kernel_log(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_logf(pInput[i]);
  }
}

void kernel_neg(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = -pInput[i];
  }
}

void kernel_abs(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_fabsf(pInput[i]);
  }
}

void kernel_sqrt(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = vx_sqrtf(pInput[i]);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_RSQRT: kernel_rsqrt(arg); break;
    case KERNEL_SIN:   kernel_sin(arg);   break;
    case KERNEL_COS:   kernel_cos(arg);   break;
    case KERNEL_EXP:   kernel_exp(arg);   break;
    case KERNEL_LOG:   kernel_log(arg);   break;
    case KERNEL_NEG:   kernel_neg(arg);   break;
    case KERNEL_ABS:   kernel_abs(arg);   break;
    case KERNEL_SQRT:  kernel_sqrt(arg);  break;
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
