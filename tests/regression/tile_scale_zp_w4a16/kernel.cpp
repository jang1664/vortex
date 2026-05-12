#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// tile_scale_zp_w4a16 — fast version (3D grid + per-element thread + shifts)
//
// Grid layout (3D — kills runtime divisions for kt/nt_dma):
//   blockIdx.z = kt
//   blockIdx.y = nt_dma
//   blockIdx.x*blockDim.x + threadIdx.x = elem_in_slot
//
// Each thread handles one 2-byte element (fp16 / int16). Inner-slot decode
// only uses compile-time MXU_NT shift + host-supplied log2 shifts for
// (cur_groups, cur_k, ng_per_mxu_nt, QBLK).
///////////////////////////////////////////////////////////////////////////////

void kernel_tile_scale_zp_w4a16(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t K          = arg->K;
  const uint32_t N          = arg->N;
  const uint32_t QBLK       = arg->QBLK;
  const uint32_t QDIR       = arg->QDIR;
  const uint32_t slot_bytes = arg->slot_bytes;
  const uint32_t body_bytes = arg->body_bytes;
  const uint32_t log2_cur_groups    = arg->log2_cur_groups;
  const uint32_t log2_cur_k         = arg->log2_cur_k;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t log2_qblk          = arg->log2_qblk;

  constexpr uint32_t MXU_NT      = TILE_DMA_MXU_NT;       // 32
  constexpr uint32_t LOG2_MXU_NT = 5;
  constexpr uint32_t MXU_NT_MASK = MXU_NT - 1;
  constexpr uint32_t MXU_PER_DMA_NT = TILE_DMA_NT / MXU_NT;  // 4

  const uint32_t kt           = blockIdx.z;
  const uint32_t nt_dma       = blockIdx.y;
  const uint32_t elem_in_slot = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t byte_in_slot = elem_in_slot * TILE_ELEM_BYTES;

  // Tail guard.
  if (byte_in_slot >= slot_bytes) return;

  // Per-slot output base.
  const uint64_t slot_base =
      (uint64_t)kt * gridDim.y * slot_bytes + (uint64_t)nt_dma * slot_bytes;
  uint8_t *dst_p = dst + slot_base + byte_in_slot;

  // Padding tail: write zero.
  if (byte_in_slot >= body_bytes) {
    *reinterpret_cast<uint16_t *>(dst_p) = 0;
    return;
  }

  // Body element. Decode (nb, ..., col-or-ng) from elem_in_slot.
  uint64_t src_byte_off;
  if (QDIR == 0) {
    // body element layout: (nb, g, col)
    const uint32_t col   = elem_in_slot & MXU_NT_MASK;
    const uint32_t nb_g  = elem_in_slot >> LOG2_MXU_NT;
    const uint32_t cg_m  = (1u << log2_cur_groups) - 1u;
    const uint32_t g     = nb_g & cg_m;
    const uint32_t nb    = nb_g >> log2_cur_groups;

    const uint32_t src_g = kt * (TILE_DMA_KT / QBLK) + g;
    const uint32_t src_c = nt_dma * TILE_DMA_NT + nb * MXU_NT + col;
    src_byte_off = ((uint64_t)src_g * N + src_c) * TILE_ELEM_BYTES;
  } else {
    // QDIR == 1: body element layout: (nb, k_loc, ng_loc)
    const uint32_t ng_m  = (1u << log2_ng_per_mxu_nt) - 1u;
    const uint32_t ng_loc = elem_in_slot & ng_m;
    const uint32_t nb_k  = elem_in_slot >> log2_ng_per_mxu_nt;
    const uint32_t ck_m  = (1u << log2_cur_k) - 1u;
    const uint32_t k_loc = nb_k & ck_m;
    const uint32_t nb    = nb_k >> log2_cur_k;

    const uint32_t global_nt_mxu = nt_dma * MXU_PER_DMA_NT + nb;
    const uint32_t global_ng_off = ((global_nt_mxu * MXU_NT) >> log2_qblk) + ng_loc;
    const uint32_t src_k         = kt * TILE_DMA_KT + k_loc;
    const uint32_t ng_total      = N >> log2_qblk;   // QBLK pow2, N multiple
    src_byte_off = ((uint64_t)src_k * ng_total + global_ng_off) * TILE_ELEM_BYTES;
  }

  *reinterpret_cast<uint16_t *>(dst_p) =
      *reinterpret_cast<const uint16_t *>(src + src_byte_off);
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_scale_zp_w4a16(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
