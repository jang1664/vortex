#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <VX_config.h>

void kernel_eladd_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input_a = reinterpret_cast<fp16_t *>(arg->input_a_addr);
  auto input_b = reinterpret_cast<fp16_t *>(arg->input_b_addr);
  auto output = reinterpret_cast<fp16_t *>(arg->output_addr);
  const uint32_t chunks_k = (arg->K + NUM_THREADS - 1u) / NUM_THREADS;
  const uint32_t total_tasks = arg->M_real * chunks_k;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t lane = thread_id & (NUM_THREADS - 1u);
  const uint32_t warp_id = thread_id / NUM_THREADS;
  const uint32_t total_warps = total_threads / NUM_THREADS;

  // One warp owns one 32-element tile chunk. Compared with tile_chunk32,
  // lanes now access adjacent elements instead of 32 independently strided
  // chunks, while the number of warp loop iterations stays the same.
  for (uint32_t task = warp_id; task < total_tasks; task += total_warps) {
    const uint32_t m = task / chunks_k;
    const uint32_t chunk = task - m * chunks_k;
    const uint32_t k = chunk * NUM_THREADS;
    const uint32_t column = k + lane;
    if (column < arg->K) {
      const uint64_t tiled_off = gemm_c_tiled_elem_offset(
          m, k, arg->M_pad, arg->K, arg->log2_mt, arg->log2_mxu_nt);
      const uint64_t row_off = (uint64_t)m * arg->K + k;
      const float a = fp16_to_float(input_a[tiled_off + lane]);
      const float b = fp16_to_float(input_b[row_off + lane]);
      output[row_off + lane] = float_to_fp16(a + b);
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_ELADD_LAYOUT_FUSED)
    kernel_eladd_layout_fused(arg);
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
