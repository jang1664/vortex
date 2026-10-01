#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

void kernel_tile_input_a(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  constexpr uint32_t CHUNK_ELEMS = 4;
  const uint32_t mt = 1u << arg->log2_mt;
  const uint32_t mt_mask = mt - 1u;
  const uint32_t mxu_kt = 1u << arg->log2_mxu_kt;
  const uint32_t mxu_kt_mask = mxu_kt - 1u;
  const uint32_t chunks_per_row = mxu_kt / CHUNK_ELEMS;

  const uint32_t ktile = blockIdx.z;
  const uint32_t kb = blockIdx.y;
  const uint32_t cidx = blockIdx.x * blockDim.x + threadIdx.x;
  if (cidx >= arg->M_pad * chunks_per_row) return;

  const uint32_t m = cidx / chunks_per_row;
  const uint32_t chunk = cidx - m * chunks_per_row;
  const uint32_t k_base = (ktile << arg->log2_kt)
                        + (kb << arg->log2_mxu_kt)
                        + chunk * CHUNK_ELEMS;
  if (k_base >= arg->K_pad) return;

  const uint32_t mt_idx = m >> arg->log2_mt;
  const uint32_t m0 = m & mt_mask;
  const uint32_t remaining_m = arg->M_pad - (mt_idx << arg->log2_mt);
  const uint32_t cm = (remaining_m < mt) ? remaining_m : mt;
  const uint32_t km = k_base >> arg->log2_mxu_kt;
  const uint32_t k0 = k_base & mxu_kt_mask;
  const uint64_t out_elem =
      (uint64_t)mt_idx * mt * arg->K_pad
    + (uint64_t)km * cm * mxu_kt
    + (uint64_t)m0 * mxu_kt + k0;

  uint64_t packed = 0;
  if (m < arg->M_real && k_base < arg->K_real) {
    const uint64_t src_elem = (uint64_t)m * arg->K_real + k_base;
    auto src_ptr = src + src_elem * TILE_ELEM_BYTES;
    if (k_base + 3u < arg->K_real && (((uintptr_t)src_ptr & 7u) == 0u)) {
      packed = *reinterpret_cast<const uint64_t *>(src_ptr);
    } else {
      const uint32_t remaining = arg->K_real - k_base;
      const uint32_t count = (remaining < CHUNK_ELEMS) ? remaining : CHUNK_ELEMS;
      for (uint32_t i = 0; i < count; ++i)
        packed |= (uint64_t)(*reinterpret_cast<const uint16_t *>(src_ptr + i * 2)) << (i * 16);
    }
  }
  *reinterpret_cast<uint64_t *>(dst + out_elem * TILE_ELEM_BYTES) = packed;
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t i = 0; i < repeat; ++i) kernel_tile_input_a(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
