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
// The build selects one of two traversal variants:
//
//   linear:  consecutive lanes process consecutive elements.
//   chunk32: each lane owns a 32-element chunk and processes it serially.
///////////////////////////////////////////////////////////////////////////////

void kernel_silu(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t size = arg->size;

  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

#ifdef SILU_USE_LINEAR
  for (uint32_t i = thread_id; i < size; i += total_threads) {
    float x = fp16_to_float(pInput[i]);
    pOutput[i] = float_to_fp16(x / (1.0f + vx_expf(-x)));
  }
#else
  constexpr uint32_t CHUNK = 32;
  constexpr uint32_t LOG2_CHUNK = 5;
  const uint32_t total_chunks = (size + CHUNK - 1) >> LOG2_CHUNK;

  for (uint32_t chunk = thread_id; chunk < total_chunks;
       chunk += total_threads) {
    const uint32_t begin = chunk << LOG2_CHUNK;
    const uint32_t end = ((begin + CHUNK) < size) ? (begin + CHUNK) : size;

    for (uint32_t i = begin; i < end; ++i) {
      float x = fp16_to_float(pInput[i]);
      pOutput[i] = float_to_fp16(x / (1.0f + vx_expf(-x)));
    }
  }
#endif
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
