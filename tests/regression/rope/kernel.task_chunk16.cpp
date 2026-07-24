#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

void kernel_rope(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);
  auto cos_table = reinterpret_cast<data_t *>(arg->cos_addr);
  auto sin_table = reinterpret_cast<data_t *>(arg->sin_addr);

  constexpr uint32_t kPairsPerTask = 16;
  const uint32_t batch_size = arg->batch_size;
  const uint32_t seq_len = arg->seq_len;
  const uint32_t num_heads = arg->num_heads;
  const uint32_t head_dim = arg->head_dim;
  const uint32_t half_dim = head_dim >> 1;
  const uint32_t chunks_per_head =
      (half_dim + kPairsPerTask - 1) / kPairsPerTask;
  const uint32_t total_tasks =
      batch_size * seq_len * num_heads * chunks_per_head;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint32_t task = thread_id; task < total_tasks;
       task += total_threads) {
    const uint32_t chunk = task % chunks_per_head;
    uint32_t logical = task / chunks_per_head;
    const uint32_t h = logical % num_heads;
    logical /= num_heads;
    const uint32_t s = logical % seq_len;
    const uint32_t b = logical / seq_len;

    const uint32_t pair_base = chunk * kPairsPerTask;
    const uint32_t pair_count =
        ((pair_base + kPairsPerTask) < half_dim)
            ? kPairsPerTask
            : (half_dim - pair_base);
    const uint32_t pos = s + arg->pos_offset;
    const uint64_t freq_base = (uint64_t)pos * half_dim + pair_base;
    const uint64_t data_base =
        (((uint64_t)b * seq_len + s) * num_heads + h) * head_dim;

    for (uint32_t pair = 0; pair < pair_count; ++pair) {
      const uint32_t p = pair_base + pair;
      const float cos_value =
          fp16_to_float(cos_table[freq_base + pair]);
      const float sin_value =
          fp16_to_float(sin_table[freq_base + pair]);
      const float x0 = fp16_to_float(input[data_base + p]);
      const float x1 = fp16_to_float(input[data_base + p + half_dim]);
      output[data_base + p] =
          float_to_fp16(x0 * cos_value - x1 * sin_value);
      output[data_base + p + half_dim] =
          float_to_fp16(x0 * sin_value + x1 * cos_value);
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_ROPE) {
    kernel_rope(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(
    const kernel_arg_t *arg) {
  return (arg->power_kernel_iterations == 0u)
             ? 1u
             : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      2, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
