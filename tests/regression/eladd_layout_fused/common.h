#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_ELADD_LAYOUT_FUSED 0

#define TILE_DMA_MT       128
#define TILE_DMA_MXU_NT    32
#define TILE_M_PAD_ALIGN    8

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_a_addr;  // fp16 GEMM-C tiled [M_pad, K]
  uint64_t input_b_addr;  // fp16 row-major residual [M_real, K]
  uint64_t output_addr;   // fp16 row-major [M_real, K]

  uint32_t M_real;
  uint32_t M_pad;
  uint32_t K;

  uint32_t log2_mt;
  uint32_t log2_mxu_nt;
} kernel_arg_t;

#endif // _COMMON_H_
