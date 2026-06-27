#ifndef _HEAD_CONCAT_LAYOUT_FUSED_COMMON_H_
#define _HEAD_CONCAT_LAYOUT_FUSED_COMMON_H_

#include <stdint.h>

#define KERNEL_HEAD_CONCAT_LAYOUT_FUSED 0

#define TILE_DMA_MT       128
#define TILE_DMA_MXU_KT    32
#define TILE_DMA_MXU_NT    32
#define TILE_M_PAD_ALIGN    8

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;   // fp16 GEMM-C tiled [batch * heads][seq_m_pad, headdim]
  uint64_t output_addr;  // fp16 GEMM-A tiled [batch * seq, heads * headdim]

  uint32_t batch;
  uint32_t seq;
  uint32_t heads;
  uint32_t headdim;
  uint32_t input_m_pad;
  uint32_t output_m_pad;

  uint32_t log2_mt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
} kernel_arg_t;

#endif // _HEAD_CONCAT_LAYOUT_FUSED_COMMON_H_
