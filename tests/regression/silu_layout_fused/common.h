#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Kernel IDs — both compiled into the same .vxbin for apples-to-apples
// perf comparison (no compile-time differences).
#define KERNEL_SILU                0
#define KERNEL_SILU_LAYOUT_FUSED   1
#define KERNEL_SILU_ROW_MATCHED    2

// Tile-layout constants — match
// tests/regression/fpint_gemm_ffn_hw/common.h
#define TILE_DMA_MT       128
#define TILE_DMA_KT       128
#define TILE_DMA_MXU_KT    32
#define TILE_DMA_MXU_NT    32

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;     // fp16 [M_real, K] row-major
  uint64_t output_addr;    // fp16 [M_real*K] flat  (plain silu)
                           // OR    [M_pad,  K] tile-laid (fused) — same buffer

  uint32_t M_real;         // real M (rows actually present)
  uint32_t M_pad;          // padded M for tile layout (multiple of 8)
  uint32_t K;
  uint32_t size;           // = M_real * K  (used only by plain silu)

  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
