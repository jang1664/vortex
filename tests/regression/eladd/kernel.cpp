#include "common.h"
#include "../vector_common/fp16.h"
#include <VX_config.h>
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = fp16_t;

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

///////////////////////////////////////////////////////////////////////////////
// Element-wise Addition Kernel
// 
// Formula: C = A + B
// 
// Critical for transformer residual connections:
// - x = x + residual (after attention)
// - x = x + residual (after FFN)
// 
// Strategy selected by the Makefile:
// - row_coalesced_cursor (default): warp-owned rows with pointer cursors
// - baseline: legacy flat grid-stride loop
///////////////////////////////////////////////////////////////////////////////

void kernel_eladd(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);

  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    auto pInputA = reinterpret_cast<data_t *>(arg->input_a_addr);
    auto pInputB = reinterpret_cast<data_t *>(arg->input_b_addr);
    auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
    uint32_t size = arg->size;

    uint32_t total_threads = gridDim.x * blockDim.x;
    uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

#if defined(ELADD_ROW_COALESCED_CURSOR)
    static_assert(ELADD_ROW_SIZE > 0, "ELADD_ROW_SIZE must be positive");
    {
      const uint32_t row_size = ELADD_ROW_SIZE;
      const uint32_t lane = thread_id % NUM_THREADS;
      const uint32_t warp_id = thread_id / NUM_THREADS;
      const uint32_t total_warps = total_threads / NUM_THREADS;
      const uint32_t num_rows = (size + row_size - 1) / row_size;

      for (uint32_t row = warp_id; row < num_rows; row += total_warps) {
        const uint32_t row_begin = row * row_size;
        const uint32_t row_length = (row_begin + row_size < size)
                                  ? row_size : size - row_begin;
        data_t* input_a_cursor = pInputA + row_begin + lane;
        data_t* input_b_cursor = pInputB + row_begin + lane;
        data_t* output_cursor = pOutput + row_begin + lane;

        for (uint32_t k = lane; k < row_length; k += NUM_THREADS) {
          float a = fp16_to_float(*input_a_cursor);
          float b = fp16_to_float(*input_b_cursor);
          *output_cursor = float_to_fp16(a + b);
          input_a_cursor += NUM_THREADS;
          input_b_cursor += NUM_THREADS;
          output_cursor += NUM_THREADS;
        }
      }
    }
#else
    {
      for (uint32_t i = thread_id; i < size; i += total_threads) {
        float a = fp16_to_float(pInputA[i]);
        float b = fp16_to_float(pInputB[i]);
        pOutput[i] = float_to_fp16(a + b);
      }
    }
#endif
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ELADD:
      kernel_eladd(arg);
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
