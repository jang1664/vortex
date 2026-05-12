#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define TILE_DMA_KT          128
#define TILE_DMA_NT          128
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
  uint32_t QDIR;

  uint32_t slot_bytes;          // bytes per (kt, nt_dma) slot incl. 512-B pad
  uint32_t body_bytes;          // bytes of real data per slot

  // Precomputed shifts (host fills; all divisors are powers of two for our shapes)
  uint32_t log2_cur_groups;     // qdir=0: log2(cur_k/QBLK)
  uint32_t log2_cur_k;          // qdir=1: log2(cur_k)
  uint32_t log2_ng_per_mxu_nt;  // qdir=1: log2(ceil(MXU_NT/QBLK))
  uint32_t log2_qblk;           // log2(QBLK)
} kernel_arg_t;

#endif // _COMMON_H_
