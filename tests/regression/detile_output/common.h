#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Tile-layout constants — must match
// tests/regression/fpint_gemm_ffn_hw/common.h
#define TILE_DMA_MT       128
#define TILE_DMA_MXU_NT   32

// Output Y is fp16 (2 bytes per element).
#define TILE_ELEM_BYTES 2

typedef struct {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;   // kernel output [M_pad, N_pad] nt-major (tile-laid)
  uint64_t dst_addr;   // [M, N_real] fp16 row-major (real rows/cols only)

  uint32_t M;          // caller's M (real rows to keep)
  uint32_t M_pad;      // padded M used by the GEMM kernel
  uint32_t N_real;     // caller's N (real columns to keep)
  uint32_t N_pad;      // padded N used by the GEMM tile layout

  uint32_t log2_mt;
  uint32_t log2_mxu_nt;
} kernel_arg_t;

#endif // _COMMON_H_
