#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// tile_input_a — fast version (3D grid + per-element thread + shifts)
//
// Grid layout:
//   blockIdx.z = kt                                  ∈ [0, k_tiles)
//   blockIdx.y = kb                                  ∈ [0, k_micros)
//   blockIdx.x*blockDim.x + threadIdx.x = mk         ∈ [0, M_pad*MXU_KT)
// Each thread copies one 2-byte fp16 element (and writes 0 for m >= M_real).
// All inner decoding uses compile-time MXU_KT (=32).
///////////////////////////////////////////////////////////////////////////////

void kernel_tile_input_a(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t M_real = arg->M_real;
  const uint32_t M_pad  = arg->M_pad;
  const uint32_t K      = arg->K;

  constexpr uint32_t MXU_KT       = TILE_DMA_MXU_KT;     // 32
  constexpr uint32_t LOG2_MXU_KT  = 5;
  constexpr uint32_t MXU_KT_MASK  = MXU_KT - 1;
  constexpr uint32_t DMA_KT       = TILE_DMA_KT;          // 128

  const uint32_t kt   = blockIdx.z;
  const uint32_t kb   = blockIdx.y;
  const uint32_t mk   = blockIdx.x * blockDim.x + threadIdx.x;

  if (mk >= M_pad * MXU_KT) return;

  const uint32_t m         = mk >> LOG2_MXU_KT;    // mk / 32
  const uint32_t k_in_sub  = mk & MXU_KT_MASK;     // mk % 32

  // Output position: sequential (kt outer, kb, m, k_in_sub)
  // bytes per kb-block = M_pad * MXU_KT * 2
  const uint64_t per_kb_bytes = (uint64_t)M_pad * MXU_KT * TILE_ELEM_BYTES;
  const uint64_t per_kt_bytes = (uint64_t)gridDim.y * per_kb_bytes;
  const uint64_t out_byte_off =
      (uint64_t)kt * per_kt_bytes
    + (uint64_t)kb * per_kb_bytes
    + (uint64_t)mk * TILE_ELEM_BYTES;

  uint16_t v = 0;
  if (m < M_real) {
    const uint32_t gk = kt * DMA_KT + kb * MXU_KT + k_in_sub;
    const uint64_t src_off = ((uint64_t)m * K + gk) * TILE_ELEM_BYTES;
    v = *reinterpret_cast<const uint16_t *>(src + src_off);
  }
  *reinterpret_cast<uint16_t *>(dst + out_byte_off) = v;
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_input_a(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
