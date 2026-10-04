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

// Keep the general row decoder out of the compact paths: its register
// pressure otherwise spills callee-saved registers even for a single row.
static __attribute__((noinline)) void elmul_padded_rows(
    kernel_arg_t *__UNIFORM__ arg, uint32_t total_threads, uint32_t thread_id) {
  auto input_a = reinterpret_cast<fp16_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<fp16_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<fp16_t *>(arg->output_addr);
  const uint32_t M = arg->M_real;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t K = arg->K;
  constexpr bool same_layout = TILE_DMA_MXU_NT == TILE_DMA_MXU_KT;
  constexpr uint32_t log2_nt = __builtin_ctz(TILE_DMA_MXU_NT);

  if (same_layout && total_threads >= TILE_DMA_MXU_NT
      && (total_threads & (TILE_DMA_MXU_NT - 1u)) == 0u) {
    // Assign one MXU_NT-wide lane group to each real row. Walking the column
    // slots by a fixed stride avoids division by a non-power-of-two M or M_pad.
    constexpr uint32_t nt = TILE_DMA_MXU_NT;
    const uint32_t mt = 1u << arg->log2_mt;
    const uint32_t row_stride = total_threads >> log2_nt;
    const uint32_t column = thread_id & (nt - 1u);
    for (uint32_t m = thread_id >> log2_nt; m < M; m += row_stride) {
      const uint32_t tile = m >> arg->log2_mt;
      const uint32_t tile_start = tile << arg->log2_mt;
      const uint32_t rows_in_tile = min_u32(M_pad - tile_start, mt);
      uint64_t offset = static_cast<uint64_t>(tile_start) * K
                      + static_cast<uint64_t>(m - tile_start) * nt + column;
      const uint64_t step = static_cast<uint64_t>(rows_in_tile) * nt;
      for (uint32_t k = column; k < K; k += nt) {
        output[offset] = float_to_fp16(
            fp16_to_float(input_a[offset]) * fp16_to_float(input_b[offset]));
        offset += step;
      }
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
    const uint64_t output_idx = gemm_a_tiled_elem_offset(
        m, k, M_pad, K, arg->log2_mt, arg->log2_mxu_kt);
    output[output_idx] = float_to_fp16(
        fp16_to_float(input_a[physical_idx]) *
        fp16_to_float(input_b[physical_idx]));
  }
}

void kernel_elmul_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input_a = reinterpret_cast<fp16_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<fp16_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<fp16_t *>(arg->output_addr);
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  // Equal C/A column widths have identical physical slot order.
  const uint32_t M = arg->M_real;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t K = arg->K;

  constexpr bool same_layout = TILE_DMA_MXU_NT == TILE_DMA_MXU_KT;
  constexpr uint32_t log2_nt = __builtin_ctz(TILE_DMA_MXU_NT);
  if (same_layout && M == M_pad) {
    const uint32_t total = M * K;
    for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
      output[idx] = float_to_fp16(
          fp16_to_float(input_a[idx]) * fp16_to_float(input_b[idx]));
    }
    return;
  }

  if (same_layout && M < TILE_DMA_MT && is_power_of_two(M)) {
    // Generation uses M=1/2/4 and M_pad=8. Within the first M tile, each
    // MXU_NT-column slot is [M_pad][MXU_NT]. Iterate the compact [M][MXU_NT]
    // useful subset and insert the padding gap with shifts and masks.
    const uint32_t log2_m = __builtin_ctz(M);
    const uint32_t log2_compact_group = log2_m + log2_nt;
    // M_pad is already the row stride; avoid a runtime ctz table lookup.
    const uint32_t padded_group = M_pad << log2_nt;
    const uint32_t compact_group_mask =
        (1u << log2_compact_group) - 1u;
    const uint32_t total = M * K;

    for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
      const uint32_t group = idx >> log2_compact_group;
      const uint32_t in_group = idx & compact_group_mask;
      const uint32_t physical_idx =
          group * padded_group + in_group;
      output[physical_idx] = float_to_fp16(
          fp16_to_float(input_a[physical_idx]) *
          fp16_to_float(input_b[physical_idx]));
    }
    return;
  }

  elmul_padded_rows(arg, total_threads, thread_id);
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
