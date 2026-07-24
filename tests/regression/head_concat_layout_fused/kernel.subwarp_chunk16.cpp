#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

static constexpr uint32_t kPairsPerChunk = 8u;
static constexpr uint32_t kTasksPerWarp = NUM_THREADS / kPairsPerChunk;

void kernel_head_concat_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<uint16_t *>(arg->input_addr);
  auto output = reinterpret_cast<uint16_t *>(arg->output_addr);
  const uint32_t chunks = arg->headdim >> 4;
  const uint32_t tasks_per_seq = arg->heads * chunks;
  const uint32_t total_tasks = arg->batch * arg->seq * tasks_per_seq;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t lane = thread_id & (NUM_THREADS - 1u);
  const uint32_t warp_id = thread_id / NUM_THREADS;
  const uint32_t total_warps = total_threads / NUM_THREADS;
  const uint32_t subgroup = lane / kPairsPerChunk;
  const uint32_t pair = lane & (kPairsPerChunk - 1u);
  const uint32_t hidden = arg->heads * arg->headdim;
  const uint64_t input_matrix_elems =
      (uint64_t)arg->input_m_pad * arg->headdim;
  const uint32_t query_heads_per_kv = arg->query_heads_per_kv;
  const uint32_t input_heads = arg->heads / query_heads_per_kv;

  // Four 8-lane subwarps each copy one 16-element chunk. Every active lane
  // issues one adjacent packed-FP16 pair instead of every lane walking a
  // different strided chunk serially.
  for (uint32_t task = warp_id * kTasksPerWarp + subgroup;
       task < total_tasks;
       task += total_warps * kTasksPerWarp) {
    const uint32_t bs = task / tasks_per_seq;
    const uint32_t hc = task - bs * tasks_per_seq;
    const uint32_t b = bs / arg->seq;
    const uint32_t s = bs - b * arg->seq;
    const uint32_t h = hc / chunks;
    const uint32_t chunk = hc - h * chunks;
    const uint32_t d = chunk << 4;
    const uint32_t m = b * arg->seq + s;
    const uint32_t input_head = h / query_heads_per_kv;
    const uint32_t group_index = h % query_heads_per_kv;
    const uint32_t input_row = group_index * arg->seq + s;
    const uint64_t in_base = batched_matrix_base(
        b * input_heads + input_head, input_matrix_elems);
    const uint64_t in_off = in_base + gemm_c_tiled_elem_offset(
        input_row, d, arg->input_m_pad, arg->headdim,
        arg->log2_mt, arg->log2_mxu_nt);
    const uint64_t out_off = gemm_a_tiled_elem_offset(
        m, h * arg->headdim + d, arg->output_m_pad, hidden,
        arg->log2_mt, arg->log2_mxu_kt);

    auto in32 = reinterpret_cast<uint32_t *>(input + in_off);
    auto out32 = reinterpret_cast<uint32_t *>(output + out_off);
    out32[pair] = in32[pair];
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_HEAD_CONCAT_LAYOUT_FUSED)
    kernel_head_concat_layout_fused(arg);
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
