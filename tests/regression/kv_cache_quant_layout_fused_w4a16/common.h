#ifndef _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_
#define _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_

#include <stdint.h>

#define KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16 0
#define SRC_LAYOUT_ROW_MAJOR 0
#define SRC_LAYOUT_GEMM_C_TILED 1
#define SRC_LAYOUT_GEMM_A_TILED 2

#define KV_QUANT_LEGACY_UINT4_ASYMMETRIC 0
#define KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC 1
#define KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC 2

#define DEFAULT_DMA_MT       128
#define DEFAULT_DMA_KT       128
#define DEFAULT_DMA_NT       128
#define TILE_DMA_MXU_KT       32
#define TILE_DMA_MXU_NT       32
#define TILE_SCALE_SLOT_ALIGN 512
#define TILE_ELEM_BYTES        2

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;     // fp16 [K, N], row-major or GEMM-A/C tiled
  uint64_t weight_addr;  // uint4 GEMM-W tiled payload
  uint64_t scale_addr;   // fp16 GEMM scale tiled
  uint64_t zero_addr;    // int16 GEMM zp tiled
  uint64_t logical_scale_addr; // optional fp16 logical-group scales
  uint64_t logical_zero_addr;  // optional fp16 fractional zero points

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;          // source quantization direction
  uint32_t GEMM_QDIR;     // output scale/zp GEMM-facing layout direction
  uint32_t WTRANS;
  uint32_t src_layout;
  uint32_t SOURCE_TRANSPOSED;
  uint32_t quant_mode;
  uint32_t src_total_N;
  uint32_t src_col_offset;
  uint32_t src_total_K;
  uint32_t src_row_offset;

  uint32_t k_tiles;
  uint32_t n_dma_tiles;
  uint32_t slot_fk_fn;
  uint32_t slot_fk_pn;
  uint32_t slot_pk_fn;
  uint32_t per_kt_full_K;
  uint32_t max_slot_bytes;

  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_nt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t log2_qblk;
  uint32_t log2_ng_per_mxu_nt;
  uint32_t persistent_mode;
  uint32_t cache_capacity;
  uint32_t cache_position;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _KV_CACHE_QUANT_LAYOUT_FUSED_W4A16_COMMON_H_
