#ifndef _HADAMARD_LAYOUT_FUSED_COMMON_H_
#define _HADAMARD_LAYOUT_FUSED_COMMON_H_

#include <stdint.h>

#define KERNEL_HADAMARD_LAYOUT_FUSED 0

#define HADAMARD_TILE_DMA_MT 128
#define HADAMARD_TILE_MXU_KT 32

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;   // fp16 [matrix_count, rows, dim], row-major
  uint64_t matrix_addr;  // fp16 [base_k, base_k]
  uint64_t output_addr;  // fp16 [matrix_count, m_pad, dim], GEMM-A tiled

  uint32_t matrix_count;
  uint32_t rows;
  uint32_t m_pad;
  uint32_t dim;
  uint32_t base_k;
  uint32_t width;
  float inv_sqrt_dim;
  uint32_t log2_mt;
  uint32_t log2_mxu_kt;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif
