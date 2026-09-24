#include <stdint.h>
#include <vx_spawn.h>
#include "common.h"

static uint32_t make_token(uint32_t block_id, uint32_t local_id) {
  return 0xc7000000u ^ (block_id * 0x10001u) ^ local_id;
}

void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
  auto dst_ptr = reinterpret_cast<resource_result_t*>(arg->dst_addr);
  auto shared = reinterpret_cast<volatile uint32_t*>(
      __local_mem(kSharedBytesPerBlock));

  uint32_t block_size = blockDim.x * blockDim.y * blockDim.z;
  uint32_t block_id = blockIdx.x
                    + blockIdx.y * gridDim.x
                    + blockIdx.z * gridDim.x * gridDim.y;
  uint32_t local_id = threadIdx.x
                    + threadIdx.y * blockDim.x
                    + threadIdx.z * blockDim.x * blockDim.y;
  uint32_t global_id = local_id + block_id * block_size;

  shared[local_id] = make_token(block_id, local_id);

  // The first site checks an ordinary block-wide shared-memory barrier.
  __syncthreads();

  uint32_t peer_id = (local_id + block_size / 2) % block_size;
  uint32_t peer_value = shared[peer_id];

  // Back-to-back sites check that the same per-block barrier ID is reusable.
  __syncthreads();
  __syncthreads();

  uintptr_t shared_addr = reinterpret_cast<uintptr_t>(shared);
  resource_result_t result = {};
  result.block_idx[0] = blockIdx.x;
  result.block_idx[1] = blockIdx.y;
  result.block_idx[2] = blockIdx.z;
  result.thread_idx[0] = threadIdx.x;
  result.thread_idx[1] = threadIdx.y;
  result.thread_idx[2] = threadIdx.z;
  result.local_group_id = __local_group_id;
  result.warps_per_group = __warps_per_group;
  result.core_id = vx_core_id();
  result.warp_id = vx_warp_id();
  result.peer_value = peer_value;
  result.lmem_addr_lo = static_cast<uint32_t>(shared_addr);
  result.lmem_addr_hi = static_cast<uint32_t>(shared_addr >> 32);
  dst_ptr[global_id] = result;
}

int main() {
  kernel_arg_t* arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_body, arg);
}
