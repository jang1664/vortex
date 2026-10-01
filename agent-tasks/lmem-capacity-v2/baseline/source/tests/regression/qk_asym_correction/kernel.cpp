#include "../vector_common/fp16.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "common.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

void kernel_qk_asym_correction(kernel_arg_t *__UNIFORM__ arg) {
  auto scores = reinterpret_cast<data_t *>(arg->scores_addr);
  auto query = reinterpret_cast<data_t *>(arg->query_addr);
  auto scale = reinterpret_cast<data_t *>(arg->scale_addr);
  auto zero = reinterpret_cast<data_t *>(arg->zero_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t row = blockIdx.x;
  const uint32_t tid = threadIdx.x;
  if (row >= arg->M)
    return;

  auto reduction = reinterpret_cast<float *>(__local_mem(blockDim.x * sizeof(float)));
  float partial = 0.0f;
  for (uint32_t d = tid; d < arg->D; d += blockDim.x) {
    const uint64_t query_index =
        (arg->query_layout == QK_QUERY_LAYOUT_GEMM_A_TILED)
        ? gemm_a_tiled_elem_offset(row, d, arg->scores_m_pad, arg->D,
                                   arg->log2_mt, arg->log2_mxu_nt)
        : (uint64_t)row * arg->D + d;
    partial += fp16_to_float(query[query_index]);
  }
  reduction[tid] = partial;
  __syncthreads();
  for (uint32_t stride = blockDim.x / 2; stride != 0; stride /= 2) {
    if (tid < stride)
      reduction[tid] += reduction[tid + stride];
    __syncthreads();
  }

  const float query_sum = reduction[0];
  for (uint32_t column = tid; column < arg->N; column += blockDim.x) {
    const uint64_t index = (arg->scores_layout == QK_SCORES_LAYOUT_GEMM_C_TILED)
        ? gemm_c_tiled_elem_offset(row, column, arg->scores_m_pad, arg->N,
                                   arg->log2_mt, arg->log2_mxu_nt)
        : (uint64_t)row * arg->N + column;
    const float correction = query_sum * fp16_to_float(scale[column]) * fp16_to_float(zero[column]);
    output[index] = float_to_fp16(fp16_to_float(scores[index]) - correction);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_QK_ASYM_CORRECTION) {
    kernel_qk_asym_correction(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t *arg) {
  return arg->power_kernel_iterations == 0 ? 1 : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  for (uint32_t i = 0; i < effective_power_kernel_iterations(arg); ++i) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
