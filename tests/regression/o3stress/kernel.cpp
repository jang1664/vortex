#include <vx_spawn.h>
#include "common.h"

static inline uint32_t rotl32(uint32_t value, uint32_t shift) {
  return (value << shift) | (value >> (32 - shift));
}

void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
  auto stride   = arg->stride;
  auto addr_ptr = (uint32_t*)arg->addr_addr;
  auto src_ptr  = (uint32_t*)arg->src_addr;
  auto dst_ptr  = (uint32_t*)arg->dst_addr;

  auto base = blockIdx.x * stride;

  for (uint32_t i = 0; i < stride; ++i) {
    uint32_t out_idx = base + i;
    uint32_t acc = 0x9e3779b9u ^ out_idx;

    for (uint32_t j = 0; j < NUM_GATHERS; ++j) {
      uint32_t addr_idx = out_idx * NUM_GATHERS + j;
      uint32_t src_idx = addr_ptr[addr_idx];
      uint32_t value = src_ptr[src_idx];
      acc = rotl32(acc ^ (value + 0x7f4a7c15u + j), 5) + (value ^ (j * 0x45d9f3bu));
    }

    dst_ptr[out_idx] = acc;

    uint32_t echo = dst_ptr[out_idx];
    uint32_t tail_idx = addr_ptr[out_idx * NUM_GATHERS + (NUM_GATHERS - 1)];
    uint32_t tail = src_ptr[tail_idx];
    dst_ptr[out_idx] = rotl32(echo, 7) ^ tail ^ (out_idx * 0x27d4eb2du);
  }
}

int main() {
  auto arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, &arg->num_tasks, nullptr, (vx_kernel_func_cb)kernel_body, arg);
}
