#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#include "../softmax_common/kernel.simt_cached.h"

struct ChunkedTiledAccessor {
  data_t *input;
  data_t *output;
  uint64_t input_row_prefix;
  uint64_t output_row_prefix;
  uint32_t input_group_stride;
  uint32_t output_group_stride;
  uint32_t log2_mxu_nt;
  uint32_t log2_mxu_kt;
  uint32_t mxu_nt_mask;
  uint32_t mxu_kt_mask;
  uint32_t tid;
  uint32_t block_size;
  mutable uint64_t input_cursor;
  mutable uint64_t output_cursor;

  void begin_load(uint32_t) const {
    const uint32_t k = tid;
    input_cursor = input_row_prefix
        + (uint64_t)(k >> log2_mxu_nt) * input_group_stride
        + (k & mxu_nt_mask);
  }

  void begin_store(uint32_t start, uint32_t) const {
    const uint32_t k = start + tid;
    output_cursor = output_row_prefix
        + (uint64_t)(k >> log2_mxu_kt) * output_group_stride
        + (k & mxu_kt_mask);
  }

  data_t load(uint32_t k) const {
    if (block_size == (1u << log2_mxu_nt)) {
      const data_t value = input[input_cursor];
      input_cursor += input_group_stride;
      return value;
    }
    const uint64_t offset = input_row_prefix
        + (uint64_t)(k >> log2_mxu_nt) * input_group_stride
        + (k & mxu_nt_mask);
    return input[offset];
  }

  void store(uint32_t k, data_t value) const {
    if (block_size == (1u << log2_mxu_kt)) {
      output[output_cursor] = value;
      output_cursor += output_group_stride;
      return;
    }
    const uint64_t offset = output_row_prefix
        + (uint64_t)(k >> log2_mxu_kt) * output_group_stride
        + (k & mxu_kt_mask);
    output[offset] = value;
  }
};

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t rows_total =
      arg->batch_size * arg->num_heads * arg->seq_len_q;
  const uint32_t mt = 1u << arg->log2_mt;
  const uint32_t mxu_nt = 1u << arg->log2_mxu_nt;
  const uint32_t mxu_kt = 1u << arg->log2_mxu_kt;
  const uint64_t input_matrix_elems =
      (uint64_t)arg->M_pad * arg->seq_len_k_pad;
  const uint64_t output_matrix_elems =
      (uint64_t)arg->M_pad * arg->output_k_pad;

  for (uint32_t row_idx = blockIdx.x;
       row_idx < rows_total;
       row_idx += gridDim.x) {
    const uint32_t matrix_idx = row_idx / arg->seq_len_q;
    const uint32_t q = row_idx - matrix_idx * arg->seq_len_q;
    const uint32_t mt_idx = q >> arg->log2_mt;
    const uint32_t m0 = q & (mt - 1u);
    const uint32_t cm = min_u32(arg->M_pad - mt_idx * mt, mt);
    const uint64_t input_row_prefix =
        (uint64_t)mt_idx * mt * arg->seq_len_k_pad
        + (uint64_t)m0 * mxu_nt;
    const uint64_t output_row_prefix =
        (uint64_t)mt_idx * mt * arg->output_k_pad
        + (uint64_t)m0 * mxu_kt;

    ChunkedTiledAccessor accessor = {
        reinterpret_cast<data_t *>(arg->input_addr)
            + batched_matrix_base(matrix_idx, input_matrix_elems),
        reinterpret_cast<data_t *>(arg->output_addr)
            + batched_matrix_base(matrix_idx, output_matrix_elems),
        input_row_prefix,
        output_row_prefix,
        cm * mxu_nt,
        cm * mxu_kt,
        arg->log2_mxu_nt,
        arg->log2_mxu_kt,
        mxu_nt - 1u,
        mxu_kt - 1u,
        threadIdx.x,
        blockDim.x,
        0,
        0,
    };
    softmax_simt_cached(accessor,
                        arg->seq_len_k,
                        arg->output_k_pad,
                        q,
                        arg->use_mask,
                        arg->scale,
                        threadIdx.x,
                        blockDim.x);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_SOFTMAX_LAYOUT_FUSED)
    kernel_softmax_layout_fused(arg);
}

static inline uint32_t effective_power_kernel_iterations(
    const kernel_arg_t *arg) {
  return arg->power_kernel_iterations == 0u
      ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
