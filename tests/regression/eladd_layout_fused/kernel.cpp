#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

using data_t = fp16_t;

void kernel_eladd_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input_a = reinterpret_cast<data_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<data_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t M = arg->M_real;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t K = arg->K;
  const uint32_t total = M * K;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t m = idx / K;
    const uint32_t k = idx - m * K;
    const uint64_t tiled_off =
        gemm_c_tiled_elem_offset(m, k, M_pad, K, arg->log2_mt, arg->log2_mxu_nt);
    float a = fp16_to_float(input_a[tiled_off]);
    float b = fp16_to_float(input_b[idx]);
    output[idx] = float_to_fp16(a + b);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ELADD_LAYOUT_FUSED:
      kernel_eladd_layout_fused(arg);
      break;
    default:
      break;
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
