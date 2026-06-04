
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>

// This is tunnable parameter for other tile size
#define GEMM_MT 128
#define GEMM_NT 128
#define GEMM_KT 128

// This is hardware specific parameter.
#define GEMM_MXU_KT MXU_ROW
#define GEMM_MXU_NT MXU_COL

// Raw instruction stream opcodes (bits [3:0] of 64-bit instruction word)
#define RAW_OP_DMA_LOAD          1
#define RAW_OP_DMA_STORE         2
#define RAW_OP_NOTIFY            3
#define RAW_OP_WAIT              4
#define RAW_OP_MXU_LOAD_WEIGHT   5
#define RAW_OP_MXU_LOAD_QPARAM   6
#define RAW_OP_MXU_LOAD_INPUT    7
#define RAW_OP_MXU_STORE_OUTPUT  8
#define RAW_OP_CLEAR             9

// Synchronization register IDs (must match HW VX_gemm_sync)
// Double-buffered: even=buf0, odd=buf1
#define RID_LD0   0
#define RID_LD1   1
#define RID_W0    2
#define RID_W1    3
#define RID_SZ0   4
#define RID_SZ1   5
#define RID_G0    6
#define RID_G1    7
#define RID_O0    8
#define RID_O1    9
#define RID_ST   10

// Kernel status codes
#define STATUS_INIT        0
#define STATUS_OK          1
#define STATUS_ALLOC_FAIL  2

typedef struct {
  // DRAM base addresses (set by host, device physical addresses)
  uint64_t dram_in_base;
  uint64_t dram_w_base;
  uint64_t dram_sc_base;
  uint64_t dram_zp_base;
  uint64_t dram_out_base;

  // LMEM base addresses — double buffered (buf0, buf1)
  uint64_t lmem_ibuf[2];
  uint64_t lmem_wbuf[2];
  uint64_t lmem_scbuf[2];
  uint64_t lmem_zpbuf[2];
  uint64_t lmem_obuf[2];

  // Problem dimensions
  uint32_t M;
  uint32_t N;
  uint32_t K;
  uint32_t QBLK;
  uint32_t WTRANS;
  uint32_t QDIR;

  // Status (written by kernel)
  uint32_t status;
} kernel_arg_t;

#endif // _COMMON_H_
