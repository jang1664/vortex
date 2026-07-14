#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Element-wise Multiplication Kernel
// 
// Formula: C = A ⊙ B (Hadamard product)
// 
// General purpose element-wise multiply used in:
// - SwiGLU: gate_act ⊙ up
// - Residual connections with scaling
// - Attention mask application
// 
// Strategy: Simple grid-stride loop, element-wise operation
///////////////////////////////////////////////////////////////////////////////

void kernel_elmul(kernel_arg_t *__UNIFORM__ arg) {
  auto pInputA = reinterpret_cast<data_t *>(arg->input_a_addr);
  auto pInputB = reinterpret_cast<data_t *>(arg->input_b_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  // Grid-stride loop
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    float a = fp16_to_float(pInputA[i]);
    float b = fp16_to_float(pInputB[i]);
    pOutput[i] = float_to_fp16(a * b);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ELMUL:
      kernel_elmul(arg);
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
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
