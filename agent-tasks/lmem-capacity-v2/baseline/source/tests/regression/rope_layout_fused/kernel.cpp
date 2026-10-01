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

  const uint32_t batch = arg->batch_size;
  const uint32_t seq_len = arg->seq_len;
  const uint32_t heads = arg->num_heads;
  const uint32_t head_dim = arg->head_dim;
  const uint32_t half_dim = head_dim >> 1;
  const uint32_t input_n = heads * head_dim;
  const uint32_t total_pairs = batch * seq_len * heads * half_dim;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  const uint64_t q_matrix_elems = (uint64_t)arg->output_m_pad * head_dim;
  const uint64_t k_matrix_elems = (uint64_t)head_dim * arg->max_seq_len;

  for (uint32_t pair_idx = thread_id; pair_idx < total_pairs; pair_idx += total_threads) {
    const uint32_t b = pair_idx / (seq_len * heads * half_dim);
    uint32_t rem = pair_idx - b * seq_len * heads * half_dim;
    const uint32_t s = rem / (heads * half_dim);
    rem -= s * heads * half_dim;
    const uint32_t h = rem / half_dim;
    const uint32_t p = rem - h * half_dim;

    const uint32_t pos = s + arg->pos_offset;
    const uint32_t input_m = b * seq_len + s;
    const uint32_t input_n0 = h * head_dim + p;
    const uint32_t input_n1 = input_n0 + half_dim;

    const uint64_t x0_off = gemm_c_tiled_elem_offset(
        input_m, input_n0, arg->input_m_pad, input_n, arg->log2_mt, arg->log2_mxu_nt);
    const uint64_t x1_off = gemm_c_tiled_elem_offset(
        input_m, input_n1, arg->input_m_pad, input_n, arg->log2_mt, arg->log2_mxu_nt);

    const float c = fp16_to_float(cos_table[(uint64_t)pos * half_dim + p]);
    const float sn = fp16_to_float(sin_table[(uint64_t)pos * half_dim + p]);
    const float x0 = fp16_to_float(input[x0_off]);
    const float x1 = fp16_to_float(input[x1_off]);
    const float y0 = x0 * c - x1 * sn;
    const float y1 = x0 * sn + x1 * c;

    const uint32_t matrix_idx = b * heads + h;
    if (arg->layout_to == ROPE_LAYOUT_TO_GEMM_A) {
      const uint64_t base = batched_matrix_base(matrix_idx, q_matrix_elems);
      const uint64_t y0_off = base + gemm_a_tiled_elem_offset(
          s, p, arg->output_m_pad, head_dim, arg->log2_mt, arg->log2_mxu_kt);
      const uint64_t y1_off = base + gemm_a_tiled_elem_offset(
          s, p + half_dim, arg->output_m_pad, head_dim, arg->log2_mt, arg->log2_mxu_kt);
      output[y0_off] = float_to_fp16(y0);
      output[y1_off] = float_to_fp16(y1);
    } else if (arg->layout_to == ROPE_LAYOUT_TO_GEMM_W) {
      const uint64_t base = batched_matrix_base(matrix_idx, k_matrix_elems);
      const uint64_t y0_off = base + gemm_w_tiled_wtrans1_elem_offset(
          p, pos, head_dim, arg->max_seq_len, arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt);
      const uint64_t y1_off = base + gemm_w_tiled_wtrans1_elem_offset(
          p + half_dim, pos, head_dim, arg->max_seq_len, arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt);
      output[y0_off] = float_to_fp16(y0);
      output[y1_off] = float_to_fp16(y1);
    } else {
      const uint64_t row_base = (arg->layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW)
          ? (((uint64_t)b * heads + h) * seq_len + s) * head_dim
          : (((uint64_t)b * seq_len + s) * heads + h) * head_dim;
      output[row_base + p] = float_to_fp16(y0);
      output[row_base + p + half_dim] = float_to_fp16(y1);
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ROPE_LAYOUT_FUSED:
      kernel_rope_layout_fused(arg);
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
