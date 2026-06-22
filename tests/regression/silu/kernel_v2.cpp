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
// Strategy: M x K traversal with a 32-wide inner K chunk. This matches the
// optimized silu_layout_fused_v2 loop nest while keeping row-major output.
///////////////////////////////////////////////////////////////////////////////

void kernel_silu(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  const uint32_t size = arg->size;
  const uint32_t M = arg->M ? arg->M : 1;
  const uint32_t K = arg->K ? arg->K : size;
  constexpr uint32_t CHUNK = 32;
  constexpr uint32_t LOG2_CHUNK = 5;

  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  uint32_t k_chunks = (K + CHUNK - 1) >> LOG2_CHUNK;

  if ((K & (CHUNK - 1)) == 0) {
    for (uint32_t m = 0; m < M; ++m) {
      uint64_t row_base = (uint64_t)m * K;
      for (uint32_t k_chunk = thread_id; k_chunk < k_chunks; k_chunk += total_threads) {
        uint32_t k_base = k_chunk << LOG2_CHUNK;

        for (uint32_t k = 0; k < CHUNK; ++k) {
          uint64_t i = row_base + k_base + k;
          float x = fp16_to_float(pInput[i]);
          pOutput[i] = float_to_fp16(x / (1.0f + vx_expf(-x)));
        }
      }
    }
    return;
  }

  for (uint32_t m = 0; m < M; ++m) {
    uint64_t row_base = (uint64_t)m * K;
    for (uint32_t k_chunk = thread_id; k_chunk < k_chunks; k_chunk += total_threads) {
      uint32_t k_base = k_chunk << LOG2_CHUNK;
      uint32_t k_end = ((k_base + CHUNK) < K) ? (k_base + CHUNK) : K;

      for (uint32_t k = k_base; k < k_end; ++k) {
        uint64_t i = row_base + k;
        float x = fp16_to_float(pInput[i]);
        pOutput[i] = float_to_fp16(x / (1.0f + vx_expf(-x)));
      }
    }
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
