#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// SiLU (Swish) Activation Kernel
// 
// Formula: SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
// 
// This is used in GLU variants (SwiGLU, GeGLU) for LLaMA-style FFN
// 
// Strategy: Simple grid-stride loop, element-wise operation
///////////////////////////////////////////////////////////////////////////////

void kernel_silu(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  // Grid-stride loop
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    float x = fp16_to_float(pInput[i]);
    // SiLU: x * sigmoid(x) = x / (1 + exp(-x))
    float sigmoid_x = 1.0f / (1.0f + vx_expf(-x));
    pOutput[i] = float_to_fp16(x * sigmoid_x);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SILU:
      kernel_silu(arg);
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
