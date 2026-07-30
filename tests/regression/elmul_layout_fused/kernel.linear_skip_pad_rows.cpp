#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

static inline bool is_power_of_two(uint32_t value) {
  return value != 0u && (value & (value - 1u)) == 0u;
}

void kernel_elmul_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input_a = reinterpret_cast<fp16_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<fp16_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<fp16_t *>(arg->output_addr);
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  // This app is compiled with MXU_NT == MXU_KT == 32, so GEMM-C inputs and
  // the GEMM-A output always have identical physical slot order.
  const uint32_t M = arg->M_real;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t K = arg->K;

  if (M == M_pad) {
    const uint32_t total = M * K;
    for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
      output[idx] = float_to_fp16(
          fp16_to_float(input_a[idx]) * fp16_to_float(input_b[idx]));
    }
    return;
  }

  if (M < TILE_DMA_MT && is_power_of_two(M)) {
    // Generation uses M=1/2/4 and M_pad=8. Within the first M tile, each
    // 32-column slot is [M_pad][32]. Iterate only the compact [M][32]
    // useful subset and insert the padding gap with shifts and masks.
    const uint32_t log2_m = __builtin_ctz(M);
    const uint32_t log2_compact_group = log2_m + 5u;
    const uint32_t log2_padded_group = __builtin_ctz(M_pad) + 5u;
    const uint32_t compact_group_mask =
        (1u << log2_compact_group) - 1u;
    const uint32_t total = M * K;

    for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
      const uint32_t group = idx >> log2_compact_group;
      const uint32_t in_group = idx & compact_group_mask;
      const uint32_t physical_idx =
          (group << log2_padded_group) + in_group;
      output[physical_idx] = float_to_fp16(
          fp16_to_float(input_a[physical_idx]) *
          fp16_to_float(input_b[physical_idx]));
    }
    return;
  }

  // Generic padded-row case: decode logical coordinates so padding rows are
  // left untouched.
  const uint32_t total = M * K;
  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t m = idx / K;
    const uint32_t k = idx - m * K;
    const uint64_t physical_idx = gemm_c_tiled_elem_offset(
        m, k, M_pad, K, arg->log2_mt, arg->log2_mxu_nt);
    output[physical_idx] = float_to_fp16(
        fp16_to_float(input_a[physical_idx]) *
        fp16_to_float(input_b[physical_idx]));
  }
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t i = 0; i < repeat; ++i) {
    kernel_elmul_layout_fused(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
