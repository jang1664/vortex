#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#include "../softmax_common/kernel.simt_cached.h"

struct AddressGenTiledAccessor {
  uintptr_t input_row_base;
  uintptr_t output_row_base;
  uintptr_t input_group_stride_bytes;
  uintptr_t output_group_stride_bytes;
  uint32_t input_group_mask;
  uint32_t output_group_mask;
  uint32_t log2_input_group_width;
  uint32_t log2_output_group_width;
  uint32_t tid;
  uint32_t block_size;

  static uint32_t range_count(uint32_t first,
                              uint32_t end,
                              uint32_t step) {
    return first < end ? 1u + (end - 1u - first) / step : 0u;
  }

  void begin_load(uint32_t end) const {
    const uint32_t first = tid;
    const uintptr_t first_address = input_row_base
        + (uintptr_t)(first >> log2_input_group_width)
            * input_group_stride_bytes
        + (uintptr_t)(first & input_group_mask) * sizeof(data_t);
    const uint32_t count = range_count(first, end, block_size);

    vx_addrgen_set_base(VX_ADDRGEN_STREAM_LD0, first_address);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 0,
                       input_group_stride_bytes, count);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 1, 0, 1);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 2, 0, 1);
    vx_addrgen_start(VX_ADDRGEN_STREAM_LD0);
  }

  void begin_store(uint32_t start, uint32_t end) const {
    const uint32_t first = start + tid;
    const uintptr_t first_address = output_row_base
        + (uintptr_t)(first >> log2_output_group_width)
            * output_group_stride_bytes
        + (uintptr_t)(first & output_group_mask) * sizeof(data_t);
    const uint32_t count = range_count(first, end, block_size);

    vx_addrgen_set_base(VX_ADDRGEN_STREAM_ST, first_address);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 0,
                       output_group_stride_bytes, count);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 1, 0, 1);
    vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 2, 0, 1);
    vx_addrgen_start(VX_ADDRGEN_STREAM_ST);
  }

  data_t load(uint32_t) const {
    data_t value = *reinterpret_cast<const data_t *>(vx_addrgen_pop_ld0());
    __asm__ volatile ("" : "+r"(value));
    return value;
  }

  void store(uint32_t, data_t value) const {
    *reinterpret_cast<data_t *>(vx_addrgen_pop_st()) = value;
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
        (uint64_t)mt_idx * mt * arg->seq_len_k_pad + (uint64_t)m0 * mxu_nt;
    const uint64_t output_row_prefix =
        (uint64_t)mt_idx * mt * arg->output_k_pad + (uint64_t)m0 * mxu_kt;
    const uint64_t input_matrix_base =
        batched_matrix_base(matrix_idx, input_matrix_elems);
    const uint64_t output_matrix_base =
        batched_matrix_base(matrix_idx, output_matrix_elems);

    AddressGenTiledAccessor accessor = {
        (uintptr_t)arg->input_addr
            + (input_matrix_base + input_row_prefix) * sizeof(data_t),
        (uintptr_t)arg->output_addr
            + (output_matrix_base + output_row_prefix) * sizeof(data_t),
        (uintptr_t)cm * mxu_nt * sizeof(data_t),
        (uintptr_t)cm * mxu_kt * sizeof(data_t),
        mxu_nt - 1u,
        mxu_kt - 1u,
        arg->log2_mxu_nt,
        arg->log2_mxu_kt,
        threadIdx.x,
        blockDim.x,
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
  if (arg->kernel_id == KERNEL_SOFTMAX_LAYOUT_FUSED) {
    kernel_softmax_layout_fused(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t *arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
