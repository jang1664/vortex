#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Tile-layout constants — must match
// tests/regression/fpint_gemm_ffn_hw/common.h
#define TILE_DMA_MT      128
#define TILE_DMA_KT      128
#define TILE_DMA_MXU_KT   32

// Input A is fp16 (2 bytes per element).
#define TILE_ELEM_BYTES 2

typedef struct {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;   // raw input A  [M_real, K_real] fp16 row-major
  uint64_t dst_addr;   // tiled output [M_pad, K_pad] fp16 (kb-major), zero-padded

  uint32_t M_real;     // real M (caller's M)
  uint32_t M_pad;      // padded M (multiple of 8)
  uint32_t K_real;     // real K (caller's K)
  uint32_t K_pad;      // padded K used by the GEMM tile layout

  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
} kernel_arg_t;

#endif // _COMMON_H_
