// Use the same reduction, cache, conversion, and iteration body as the
// layout-fused cursor variant, with contiguous row-major pointers.
#include "common.h"
#include <VX_config.h>
#define TILE_DMA_MXU_NT NUM_THREADS
#define TILE_DMA_MXU_KT NUM_THREADS
#define SOFTMAX_REV2_SHUFFLE_CURSOR 1
#include "../softmax_common/kernel.shuffle_cached.h"

struct RowAccessor {
  data_t* input;
  data_t* output;
  uint64_t input_row_prefix;
  uint64_t output_row_prefix;
  uint32_t input_group_stride;
  uint32_t output_group_stride;
  data_t load(uint32_t k) const { return input[k]; }
  void store(uint32_t k, data_t value) const { output[k] = value; }
};

void kernel_softmax(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t rows_total = arg->batch_size * arg->num_heads * arg->seq_len_q;
  for (uint32_t row_idx = blockIdx.x; row_idx < rows_total; row_idx += gridDim.x) {
    auto input = reinterpret_cast<data_t*>(arg->input_addr
        + (uint64_t)row_idx * arg->row_pitch_bytes);
    auto output = reinterpret_cast<data_t*>(arg->output_addr
        + (uint64_t)row_idx * arg->row_pitch_bytes);
    const RowAccessor accessor = {input, output, 0, 0, NUM_THREADS, NUM_THREADS};
    softmax_shuffle_cached(accessor, arg->seq_len_k, row_idx % arg->seq_len_q,
        arg->use_mask, arg->scale, threadIdx.x);
  }
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = arg->power_kernel_iterations ? arg->power_kernel_iterations : 1u;
  for (uint32_t iteration = 0; iteration < repeat; ++iteration) {
    if (arg->kernel_id == KERNEL_SOFTMAX) kernel_softmax(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
