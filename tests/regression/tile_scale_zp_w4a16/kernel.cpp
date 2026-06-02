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
  const uint32_t SOURCE_QDIR = arg->QDIR;
  const uint32_t GEMM_QDIR   = arg->GEMM_QDIR;
  const uint32_t SOURCE_TRANSPOSED = arg->SOURCE_TRANSPOSED;
  const uint32_t k_tiles    = arg->k_tiles;
  const uint32_t n_dma_tiles = arg->n_dma_tiles;
  const uint32_t slot_fk_fn = arg->slot_fk_fn;
  const uint32_t slot_fk_pn = arg->slot_fk_pn;
  const uint32_t slot_pk_fn = arg->slot_pk_fn;
  const uint32_t per_kt_full_K = arg->per_kt_full_K;
  const uint32_t max_slot_bytes = arg->max_slot_bytes;
  const uint32_t log2_kt       = arg->log2_kt;
  const uint32_t log2_nt       = arg->log2_nt;
  const uint32_t log2_mxu_nt   = arg->log2_mxu_nt;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t log2_qblk          = arg->log2_qblk;

  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t nt_size = 1u << log2_nt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t mxu_nt_mask = mxu_nt - 1u;
  const uint32_t mxu_per_dma_nt = nt_size >> log2_mxu_nt;

  const uint32_t kt           = blockIdx.z;
  const uint32_t nt_dma       = blockIdx.y;
  const uint32_t elem_in_slot = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t byte_in_slot = elem_in_slot * TILE_ELEM_BYTES;

  const uint32_t out_K = SOURCE_TRANSPOSED ? N : K;
  const uint32_t out_N = SOURCE_TRANSPOSED ? K : N;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t nt_start = nt_dma << log2_nt;
  const uint32_t cur_k = ((out_K - kt_start) < kt_size) ? (out_K - kt_start) : kt_size;
  const uint32_t cur_n = ((out_N - nt_start) < nt_size) ? (out_N - nt_start) : nt_size;
  const uint32_t cur_nb = cur_n >> log2_mxu_nt;
  const uint32_t cur_groups = cur_k >> log2_qblk;
  const uint32_t ng_per_mxu_nt = 1u << log2_ng_per_mxu_nt;

  uint32_t body_bytes;
  if (GEMM_QDIR == 0) {
    body_bytes = cur_groups * cur_n * TILE_ELEM_BYTES;
  } else {
    body_bytes = cur_nb * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
  }
  const uint32_t slot_bytes = (body_bytes + (TILE_SCALE_SLOT_ALIGN - 1u))
                            & ~(TILE_SCALE_SLOT_ALIGN - 1u);

  if (byte_in_slot >= max_slot_bytes || byte_in_slot >= slot_bytes) return;

  const uint32_t slot_full_N = (kt + 1u == k_tiles) ? slot_pk_fn : slot_fk_fn;
  const uint64_t slot_base = (uint64_t)kt * per_kt_full_K
                           + (uint64_t)nt_dma * slot_full_N;
  (void)n_dma_tiles;
  (void)slot_fk_pn;

  uint8_t *dst_p = dst + slot_base + byte_in_slot;

  // Padding tail: write zero.
  if (byte_in_slot >= body_bytes) {
    *reinterpret_cast<uint16_t *>(dst_p) = 0;
    return;
  }

  // Body element. Decode (nb, ..., col-or-ng) from elem_in_slot.
  uint64_t src_byte_off;
  uint32_t out_k = kt_start;
  uint32_t out_n = nt_start;
  if (GEMM_QDIR == 0) {
    // body element layout: (nb, g, col)
    const uint32_t col   = elem_in_slot & mxu_nt_mask;
    const uint32_t nb_g  = elem_in_slot >> log2_mxu_nt;
    const uint32_t g     = nb_g % cur_groups;
    const uint32_t nb    = nb_g / cur_groups;

    out_k = kt_start + (g << log2_qblk);
    out_n = nt_start + (nb << log2_mxu_nt) + col;
  } else {
    // GEMM_QDIR == 1: body element layout: (nb, k_loc, ng_loc)
    const uint32_t ng_m  = ng_per_mxu_nt - 1u;
    const uint32_t ng_loc = elem_in_slot & ng_m;
    const uint32_t nb_k  = elem_in_slot >> log2_ng_per_mxu_nt;
    const uint32_t k_loc = nb_k % cur_k;
    const uint32_t nb    = nb_k / cur_k;

    const uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
    const uint32_t global_ng_off = ((global_nt_mxu << log2_mxu_nt) >> log2_qblk) + ng_loc;
    out_k = kt_start + k_loc;
    out_n = global_ng_off << log2_qblk;
  }

  const uint32_t source_row = SOURCE_TRANSPOSED ? out_n : out_k;
  const uint32_t source_col = SOURCE_TRANSPOSED ? out_k : out_n;
  if (SOURCE_QDIR == 0) {
    const uint32_t source_g = source_row >> log2_qblk;
    src_byte_off = ((uint64_t)source_g * N + source_col) * TILE_ELEM_BYTES;
  } else {
    const uint32_t source_ng_total = N >> log2_qblk;
    const uint32_t source_ng = source_col >> log2_qblk;
    src_byte_off = ((uint64_t)source_row * source_ng_total + source_ng) * TILE_ELEM_BYTES;
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
