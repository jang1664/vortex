#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// Per-token int4 dequantization kernel
//
// Matches spinquant_inference/utils/quant_utils.py: dequantize_per_token()
// with groupsize == D (one scale/zero per row).
//
//   sym  (mode == QMODE_SYM):   x_i = scale * q_i
//   asym (mode == QMODE_ASYM):  x_i = scale * (q_i - zero)
//
// Strategy: simple grid-stride elementwise loop over all [n_rows, D]
// elements (same pattern as kv_cache_dequant_w4a16).
///////////////////////////////////////////////////////////////////////////////

void kernel_dequantize_pt_int4(kernel_arg_t *__UNIFORM__ arg) {
  auto pQ = reinterpret_cast<int8_t *>(arg->q_addr);
  auto pScale = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto pZero = reinterpret_cast<fp16_t *>(arg->zero_addr);
  auto pOutput = reinterpret_cast<fp16_t *>(arg->output_addr);

  const uint32_t n_rows = arg->n_rows;
  const uint32_t D = arg->D;
  const uint32_t mode = arg->mode;
  const uint64_t total = (uint64_t)n_rows * D;

  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint64_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t row = (uint32_t)(idx / D);
    const float scale = fp16_to_float(pScale[row]);
    const float qv = (float)pQ[idx];

    float x;
    if (mode == QMODE_SYM) {
      x = scale * qv;
    } else {
      const float zero = fp16_to_float(pZero[row]);
      x = scale * (qv - zero);
    }
    pOutput[idx] = float_to_fp16(x);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_DEQUANTIZE_PT_INT4:
      kernel_dequantize_pt_int4(arg);
      break;
    default:
      break;
  }
}

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
