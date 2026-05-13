#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

///////////////////////////////////////////////////////////////////////////////
// tile_weight_w4a16 — fast version (3D grid + 16-B per thread)
//
// Reorders packed-int4 weight from row-major [K, N/2] to the tile-major
// layout the fpint_gemm_ffn_hw kernel expects in DRAM. Mirrors
// fpint_gemm_ffn_hw/main.cpp::convert_weight_tiled:
//
//   for kt:   for nt:   for kb:   for k_in_sub:   for pair:
//     dst[idx++] = src[ (kt*DMA_KT + kb*MXU_KT + k_in_sub) * (N/2)
//                       + nt*pair_per_sub + pair ]
//
// Grid layout (3D — avoids ALL runtime divisions):
//   blockIdx.z = kt                                   ∈ [0, k_tiles)
//   blockIdx.y = nt                                   ∈ [0, n_tiles)
//   blockIdx.x * blockDim.x + threadIdx.x = cnk       ∈ [0, cur_kb*MXU_KT)
//
// Each thread copies ONE 16-byte chunk (the inner "pair" loop, flattened).
// Inside-block divisions are by MXU_KT (compile-time = 32 → shift).
///////////////////////////////////////////////////////////////////////////////

void kernel_tile_weight_w4a16(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<uint8_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;

  constexpr uint32_t MXU_KT       = TILE_DMA_MXU_KT;       // 32
  constexpr uint32_t MXU_NT       = TILE_DMA_MXU_NT;       // 32
  constexpr uint32_t DMA_KT       = TILE_DMA_KT;            // 128
  constexpr uint32_t PAIR_PER_SUB = MXU_NT / 2;             // 16  (one chunk)
  constexpr uint32_t LOG2_MXU_KT  = 5;                       // log2(32)
  constexpr uint32_t MXU_KT_MASK  = MXU_KT - 1;             // 31

  const uint32_t k_tiles  = (K + DMA_KT - 1) / DMA_KT;
  const uint32_t cur_k    = (k_tiles == 1) ? K : DMA_KT;
  const uint32_t cur_kb   = cur_k / MXU_KT;                  // K-sub-tiles per K-tile
  const uint32_t n_tiles  = N / MXU_NT;
  const uint32_t row_bytes = N / 2;

  const uint32_t kt  = blockIdx.z;
  const uint32_t nt  = blockIdx.y;
  const uint32_t cnk = blockIdx.x * blockDim.x + threadIdx.x;

  // Guard tail threads when (cur_kb*MXU_KT) isn't a multiple of blockDim.x.
  const uint32_t chunks_per_nt_kt = cur_kb * MXU_KT;
  if (cnk >= chunks_per_nt_kt) return;

  const uint32_t kb       = cnk >> LOG2_MXU_KT;       // cnk / 32
  const uint32_t k_in_sub = cnk & MXU_KT_MASK;        // cnk % 32

  const uint32_t gk = kt * DMA_KT + kb * MXU_KT + k_in_sub;
  const uint64_t src_off =
      (uint64_t)gk * row_bytes + (uint64_t)nt * PAIR_PER_SUB;

  // Output chunks are laid out (kt, nt, kb, k_in_sub) in sequence.
  const uint64_t chunk_idx =
      (uint64_t)kt * n_tiles * chunks_per_nt_kt
    + (uint64_t)nt * chunks_per_nt_kt
    + cnk;
  const uint64_t dst_off = chunk_idx * PAIR_PER_SUB;

  // 16-byte copy: two 64-bit loads/stores (src/dst are both 16-B aligned).
  uint64_t* sp = reinterpret_cast<uint64_t*>(src + src_off);
  uint64_t* dp = reinterpret_cast<uint64_t*>(dst + dst_off);
  dp[0] = sp[0];
  dp[1] = sp[1];
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  kernel_tile_weight_w4a16(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(3, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
