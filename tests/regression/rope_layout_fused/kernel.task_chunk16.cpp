#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

using data_t = fp16_t;

void kernel_rope_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);
  auto cos_table = reinterpret_cast<data_t *>(arg->cos_addr);
  auto sin_table = reinterpret_cast<data_t *>(arg->sin_addr);

  const uint32_t seq_len = arg->seq_len;
  const uint32_t heads = arg->num_heads;
  const uint32_t head_dim = arg->head_dim;
  const uint32_t half_dim = head_dim >> 1;
  const uint32_t input_n = heads * head_dim;
  const uint32_t chunks = (half_dim + 15u) >> 4;
  const uint32_t tasks_per_seq = heads * chunks;
  const uint32_t total_tasks = arg->batch_size * seq_len * tasks_per_seq;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint64_t q_matrix_elems = (uint64_t)arg->output_m_pad * head_dim;
  const uint64_t k_matrix_elems = (uint64_t)head_dim * arg->max_seq_len;

  for (uint32_t task = thread_id; task < total_tasks; task += total_threads) {
    const uint32_t bs = task / tasks_per_seq;
    const uint32_t hc = task - bs * tasks_per_seq;
    const uint32_t b = bs / seq_len;
    const uint32_t s = bs - b * seq_len;
    const uint32_t h = hc / chunks;
    const uint32_t chunk = hc - h * chunks;
    const uint32_t p_begin = chunk << 4;
    const uint32_t p_end = ((p_begin + 16u) < half_dim) ? (p_begin + 16u) : half_dim;
    const uint32_t pos = s + arg->pos_offset;
    const uint32_t input_m = b * seq_len + s;
    const uint32_t head_base = h * head_dim;
    const uint32_t matrix_idx = b * heads + h;

    if (arg->layout_to == ROPE_LAYOUT_TO_GEMM_A) {
      const uint64_t out_base = batched_matrix_base(matrix_idx, q_matrix_elems);
      for (uint32_t p = p_begin; p < p_end; ++p) {
        const uint64_t x0_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const uint64_t x1_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p + half_dim, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const float c = fp16_to_float(cos_table[(uint64_t)pos * half_dim + p]);
        const float sn = fp16_to_float(sin_table[(uint64_t)pos * half_dim + p]);
        const float x0 = fp16_to_float(input[x0_off]);
        const float x1 = fp16_to_float(input[x1_off]);
        const uint64_t y0_off = out_base + gemm_a_tiled_elem_offset(
            s, p, arg->output_m_pad, head_dim, arg->log2_mt, arg->log2_mxu_kt);
        const uint64_t y1_off = out_base + gemm_a_tiled_elem_offset(
            s, p + half_dim, arg->output_m_pad, head_dim,
            arg->log2_mt, arg->log2_mxu_kt);
        output[y0_off] = float_to_fp16(x0 * c - x1 * sn);
        output[y1_off] = float_to_fp16(x0 * sn + x1 * c);
      }
    } else if (arg->layout_to == ROPE_LAYOUT_TO_GEMM_W) {
      const uint64_t out_base = batched_matrix_base(matrix_idx, k_matrix_elems);
      for (uint32_t p = p_begin; p < p_end; ++p) {
        const uint64_t x0_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const uint64_t x1_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p + half_dim, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const float c = fp16_to_float(cos_table[(uint64_t)pos * half_dim + p]);
        const float sn = fp16_to_float(sin_table[(uint64_t)pos * half_dim + p]);
        const float x0 = fp16_to_float(input[x0_off]);
        const float x1 = fp16_to_float(input[x1_off]);
        const uint64_t y0_off = out_base + gemm_w_tiled_wtrans1_elem_offset(
            p, pos, head_dim, arg->max_seq_len,
            arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt);
        const uint64_t y1_off = out_base + gemm_w_tiled_wtrans1_elem_offset(
            p + half_dim, pos, head_dim, arg->max_seq_len,
            arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt);
        output[y0_off] = float_to_fp16(x0 * c - x1 * sn);
        output[y1_off] = float_to_fp16(x0 * sn + x1 * c);
      }
    } else {
      const uint64_t out_base = (arg->layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW)
          ? (((uint64_t)b * heads + h) * seq_len + s) * head_dim
          : (((uint64_t)b * seq_len + s) * heads + h) * head_dim;
      for (uint32_t p = p_begin; p < p_end; ++p) {
        const uint64_t x0_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const uint64_t x1_off = gemm_c_tiled_elem_offset(
            input_m, head_base + p + half_dim, arg->input_m_pad, input_n,
            arg->log2_mt, arg->log2_mxu_nt);
        const float c = fp16_to_float(cos_table[(uint64_t)pos * half_dim + p]);
        const float sn = fp16_to_float(sin_table[(uint64_t)pos * half_dim + p]);
        const float x0 = fp16_to_float(input[x0_off]);
        const float x1 = fp16_to_float(input[x1_off]);
        output[out_base + p] = float_to_fp16(x0 * c - x1 * sn);
        output[out_base + p + half_dim] = float_to_fp16(x0 * sn + x1 * c);
      }
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_ROPE_LAYOUT_FUSED) kernel_rope_layout_fused(arg);
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) kernel_dispatcher(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
