#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Tile-layout constants — must match
// tests/regression/fpint_gemm_ffn_hw/common.h
#define TILE_DMA_KT       128
#define TILE_DMA_MXU_KT    32
#define TILE_DMA_MXU_NT    32

typedef struct {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;     // packed weight [K, N/2] uint8 row-major
  uint64_t dst_addr;     // tiled weight (same numel), kt-nt-kb-k-pair layout

  uint32_t K;            // weight rows (K)
  uint32_t N;            // weight output channels (N) — packed dim is N/2
  uint32_t WTRANS;       // 0: pack n-pairs, 1: pack k-pairs

  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
} kernel_arg_t;

#endif // _COMMON_H_
