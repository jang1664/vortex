#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define DEFAULT_DMA_MT       128
#define DEFAULT_DMA_KT       128
#define DEFAULT_DMA_NT       128
#define TILE_DMA_MXU_KT       32
#define TILE_DMA_MXU_NT       32
#define TILE_SCALE_SLOT_ALIGN 512
#define TILE_ELEM_BYTES        2

typedef struct {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;
  uint64_t dst_addr;

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;          // source qparam direction
  uint32_t GEMM_QDIR;     // output GEMM-facing qparam layout direction
  uint32_t SOURCE_TRANSPOSED;

  uint32_t k_tiles;
  uint32_t n_dma_tiles;

  uint32_t slot_fk_fn;          // full-K, full-N slot bytes
  uint32_t slot_fk_pn;          // full-K, partial/last-N slot bytes
  uint32_t slot_pk_fn;          // partial/last-K, full-N slot bytes
  uint32_t per_kt_full_K;       // bytes in a full-K kt row of N slots
  uint32_t max_slot_bytes;      // launch bound for the largest slot

  // Precomputed shifts (host fills; all divisors are powers of two for our shapes)
  uint32_t log2_kt;
  uint32_t log2_nt;
  uint32_t log2_mxu_nt;
  uint32_t log2_qblk;           // log2(QBLK)
  uint32_t log2_ng_per_mxu_nt;  // qdir=1: log2(ceil(MXU_NT/QBLK))
  uint32_t flat_mode;            // 1: transposed K qparams, 2: V qparam replication
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
