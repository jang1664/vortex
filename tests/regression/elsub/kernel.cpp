#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Element-wise Subtraction Kernel
// 
// Formula: C = A - B
// 
// Used in transformer residual computations and gradient calculations
///////////////////////////////////////////////////////////////////////////////

void kernel_elsub(kernel_arg_t *__UNIFORM__ arg) {
  auto pInputA = reinterpret_cast<data_t *>(arg->input_a_addr);
  auto pInputB = reinterpret_cast<data_t *>(arg->input_b_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t size = arg->size;
  
  // Grid-stride loop
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    pOutput[i] = pInputA[i] - pInputB[i];
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ELSUB:
      kernel_elsub(arg);
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
