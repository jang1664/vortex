#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

void kernel_elmul_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input_a = reinterpret_cast<fp16_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<fp16_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<fp16_t *>(arg->output_addr);
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  if (arg->log2_mxu_nt == arg->log2_mxu_kt
      && arg->M_real == arg->M_pad) {
    // GEMM-C inputs and GEMM-A output have identical physical slot order.
    const uint32_t total = arg->M_real * arg->K;
    for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
      const float a = fp16_to_float(input_a[idx]);
      const float b = fp16_to_float(input_b[idx]);
      output[idx] = float_to_fp16(a * b);
    }
    return;
  }

  // Generic fallback for future configurations with different C/A widths.
  const uint32_t total = arg->M_real * arg->K;
  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t m = idx / arg->K;
    const uint32_t k = idx - m * arg->K;
    const uint64_t in_off = gemm_c_tiled_elem_offset(
        m, k, arg->M_pad, arg->K, arg->log2_mt, arg->log2_mxu_nt);
    const uint64_t out_off = gemm_a_tiled_elem_offset(
        m, k, arg->M_pad, arg->K, arg->log2_mt, arg->log2_mxu_kt);
    output[out_off] = float_to_fp16(
        fp16_to_float(input_a[in_off]) * fp16_to_float(input_b[in_off]));
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t i = 0; i < repeat; ++i) kernel_elmul_layout_fused(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
