#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_SOFTMAX_LAYOUT_FUSED 0
#define SOFTMAX_LAYOUT_FUSED_VARIANT_REV1 0
#define SOFTMAX_LAYOUT_FUSED_VARIANT_OPT 1

#define TILE_DMA_MT       128
#define TILE_DMA_KT       128
#define TILE_DMA_MXU_KT    32
#define TILE_DMA_MXU_NT    32
#define TILE_M_PAD_ALIGN    8

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;   // fp16 GEMM-C tiled scores, one matrix per batch/head
  uint64_t output_addr;  // fp16 GEMM-A tiled probabilities

  uint32_t batch_size;
  uint32_t num_heads;
  uint32_t seq_len_q;
  uint32_t seq_len_k;
  uint32_t seq_len_k_pad;
  uint32_t M_pad;

  uint32_t use_mask;
  float scale;

  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
