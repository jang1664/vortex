#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

void kernel_detile_output(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t mt = 1u << arg->log2_mt;
  const uint32_t mt_mask = mt - 1u;
  const uint32_t mxu_nt = 1u << arg->log2_mxu_nt;

  const uint32_t nt = blockIdx.z;
  const uint32_t m = blockIdx.y;
  const uint32_t pair = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t ncol = pair << 1;
  const uint32_t n = (nt << arg->log2_mxu_nt) + ncol;
  if (ncol >= mxu_nt || m >= arg->M || n >= arg->N_real) return;

  const uint32_t mt_idx = m >> arg->log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t remaining_m = arg->M_pad - (mt_idx << arg->log2_mt);
  const uint32_t cm = (remaining_m < mt) ? remaining_m : mt;
  const uint64_t src_elem =
      (uint64_t)mt_idx * mt * arg->N_pad
    + (uint64_t)nt * cm * mxu_nt
    + (uint64_t)m0 * mxu_nt + ncol;
  const uint64_t dst_elem = (uint64_t)m * arg->N_real + n;
  const uint32_t packed = *reinterpret_cast<const uint32_t *>(
      src + src_elem * TILE_ELEM_BYTES);
  auto dst_ptr = dst + dst_elem * TILE_ELEM_BYTES;

  if (n + 1u < arg->N_real && (((uintptr_t)dst_ptr & 3u) == 0u)) {
    *reinterpret_cast<uint32_t *>(dst_ptr) = packed;
  } else {
    *reinterpret_cast<uint16_t *>(dst_ptr) = (uint16_t)packed;
    if (n + 1u < arg->N_real)
      *reinterpret_cast<uint16_t *>(dst_ptr + 2) = (uint16_t)(packed >> 16);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t i = 0; i < repeat; ++i) kernel_detile_output(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
