#include "common.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = uint16_t;

void kernel_head_concat(kernel_arg_t *__UNIFORM__ arg) {
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

  for (uint32_t idx = thread_id; idx < total; idx += total_threads) {
    const uint32_t d = idx % headdim;
    const uint32_t tmp = idx / headdim;
    const uint32_t h = tmp % heads;
    const uint32_t s = (tmp / heads) % seq;
    const uint32_t b = tmp / (heads * seq);

    const uint64_t in_off =
        (((uint64_t)b * heads + h) * seq + s) * headdim + d;
    output[idx] = input[in_off];
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_HEAD_CONCAT:
      kernel_head_concat(arg);
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
