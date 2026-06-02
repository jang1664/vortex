#ifndef _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_
#define _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_

#include <stdint.h>

#define KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16 0
#define SRC_LAYOUT_ROW_MAJOR 0
#define SRC_LAYOUT_GEMM_C_TILED 1

#define TILE_DMA_MT          128
#define TILE_DMA_KT          128
#define TILE_DMA_NT          128
#define TILE_DMA_MXU_KT       32
#define TILE_DMA_MXU_NT       32
#define TILE_SCALE_SLOT_ALIGN 512
#define TILE_ELEM_BYTES        2

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;     // fp16 [K, N], row-major or GEMM-C tiled
  uint64_t weight_addr;  // uint4 GEMM-W tiled payload
  uint64_t scale_addr;   // fp16 GEMM scale tiled
  uint64_t zero_addr;    // int16 GEMM zp tiled

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;
  uint32_t WTRANS;
  uint32_t src_layout;

  uint32_t k_tiles;
  uint32_t n_dma_tiles;
  uint32_t slot_fk_fn;
  uint32_t slot_fk_pn;
  uint32_t slot_pk_fn;
  uint32_t per_kt_full_K;
  uint32_t max_slot_bytes;

  uint32_t log2_kt;
  uint32_t log2_nt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t log2_qblk;
  uint32_t log2_ng_per_mxu_nt;
} kernel_arg_t;

#endif // _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_
