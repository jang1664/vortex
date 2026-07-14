#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = uint16_t;

void kernel_head_concat_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t batch = arg->batch;
  const uint32_t seq = arg->seq;
  const uint32_t heads = arg->heads;
  const uint32_t headdim = arg->headdim;
  const uint32_t hidden = heads * headdim;
  const uint32_t total = batch * seq * hidden;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint64_t input_matrix_elems = (uint64_t)arg->input_m_pad * headdim;

  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t d = idx % headdim;
    const uint32_t tmp = idx / headdim;
    const uint32_t h = tmp % heads;
    const uint32_t s = (tmp / heads) % seq;
    const uint32_t b = tmp / (heads * seq);
    const uint32_t m = b * seq + s;
    const uint32_t k = h * headdim + d;

    const uint32_t input_matrix = b * heads + h;
    const uint64_t in_base = batched_matrix_base(input_matrix, input_matrix_elems);
    const uint64_t in_off = in_base + gemm_c_tiled_elem_offset(
        s, d, arg->input_m_pad, headdim, arg->log2_mt, arg->log2_mxu_nt);
    const uint64_t out_off = gemm_a_tiled_elem_offset(
        m, k, arg->output_m_pad, hidden, arg->log2_mt, arg->log2_mxu_kt);
    output[out_off] = input[in_off];
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_HEAD_CONCAT_LAYOUT_FUSED:
      kernel_head_concat_layout_fused(arg);
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
