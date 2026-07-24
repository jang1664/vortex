#include "common.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = uint16_t;

void kernel_head_concat(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  constexpr uint32_t kChunk = 16;
  const uint32_t batch = arg->batch;
  const uint32_t seq = arg->seq;
  const uint32_t heads = arg->heads;
  const uint32_t headdim = arg->headdim;
  const uint32_t chunks_per_head = (headdim + kChunk - 1) / kChunk;
  const uint32_t total_tasks = batch * seq * heads * chunks_per_head;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint32_t task = thread_id; task < total_tasks; task += total_threads) {
    const uint32_t chunk = task % chunks_per_head;
    uint32_t logical = task / chunks_per_head;
    const uint32_t h = logical % heads;
    logical /= heads;
    const uint32_t s = logical % seq;
    const uint32_t b = logical / seq;

    const uint32_t d_base = chunk * kChunk;
    const uint32_t count =
        ((d_base + kChunk) < headdim) ? kChunk : (headdim - d_base);
    const uint64_t in_base =
        (((uint64_t)b * heads + h) * seq + s) * headdim + d_base;
    const uint64_t out_base =
        (((uint64_t)b * seq + s) * heads + h) * headdim + d_base;

    if ((headdim & 1u) == 0u) {
      auto packed_input =
          reinterpret_cast<const uint32_t *>(input + in_base);
      auto packed_output =
          reinterpret_cast<uint32_t *>(output + out_base);
      const uint32_t pairs = count >> 1;
      for (uint32_t pair = 0; pair < pairs; ++pair) {
        packed_output[pair] = packed_input[pair];
      }
      if (count & 1u) {
        output[out_base + count - 1] = input[in_base + count - 1];
      }
    } else {
      for (uint32_t d = 0; d < count; ++d) {
        output[out_base + d] = input[in_base + d];
      }
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_HEAD_CONCAT) {
    kernel_head_concat(arg);
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
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
