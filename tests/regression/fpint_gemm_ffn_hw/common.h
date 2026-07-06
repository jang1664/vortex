
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>

// Runtime-programmed DMA tile dimensions. These remain pow2-only; the kernel
// writes their log2 values into descriptor registers 40..42.
#define GEMM_MT 128
#define GEMM_NT 128
#define GEMM_KT 128

#define GEMM_MXU_KT MXU_ROW
#define GEMM_MXU_NT MXU_COL

// Job descriptor register indices.
#define REG_CONTROL             0
#define REG_INPUT_BASE_LO       1
#define REG_INPUT_BASE_HI       2
#define REG_WEIGHT_BASE_LO      3
#define REG_WEIGHT_BASE_HI      4
#define REG_OUTPUT_BASE_LO      5
#define REG_OUTPUT_BASE_HI      6
#define REG_SCALE_BASE_LO       7
#define REG_SCALE_BASE_HI       8
#define REG_ZP_BASE_LO          9
#define REG_ZP_BASE_HI          10
#define REG_LMEM_IBUF0_LO       11
#define REG_LMEM_IBUF0_HI       12
#define REG_LMEM_IBUF1_LO       13
#define REG_LMEM_IBUF1_HI       14
#define REG_LMEM_WBUF0_LO       15
#define REG_LMEM_WBUF0_HI       16
#define REG_LMEM_WBUF1_LO       17
#define REG_LMEM_WBUF1_HI       18
#define REG_LMEM_SCBUF0_LO      19
#define REG_LMEM_SCBUF0_HI      20
#define REG_LMEM_SCBUF1_LO      21
#define REG_LMEM_SCBUF1_HI      22
#define REG_LMEM_ZPBUF0_LO      23
#define REG_LMEM_ZPBUF0_HI      24
#define REG_LMEM_ZPBUF1_LO      25
#define REG_LMEM_ZPBUF1_HI      26
#define REG_LMEM_OBUF_LO        27
#define REG_LMEM_OBUF_HI        28
#define REG_M_ORIG              29
#define REG_N_ORIG              30
#define REG_K_ORIG              31
#define REG_QBLK_ORIG           32
#define REG_M_TARGET            33
#define REG_N_TARGET            34
#define REG_K_TARGET            35
#define REG_M_START             36
#define REG_N_START             37
#define REG_WTRANS              38
#define REG_QDIR                39
#define REG_LOG2_DMA_MT         40
#define REG_LOG2_DMA_KT         41
#define REG_LOG2_DMA_NT         42

#define GEMM_JOB_NUM_REGS32     43
#define GEMM_JOB_NUM_ENTRIES    4

#define STATUS_INIT        0
#define STATUS_OK          1
#define STATUS_ALLOC_FAIL  2
#define STATUS_WAIT_STUCK  3
#define STATUS_BAD_EID     4

typedef struct {
  uint64_t dram_in_base;
  uint64_t dram_w_base;
  uint64_t dram_sc_base;
  uint64_t dram_zp_base;
  uint64_t dram_out_base;

  uint64_t lmem_ibuf[2];
  uint64_t lmem_wbuf[2];
  uint64_t lmem_scbuf[2];
  uint64_t lmem_zpbuf[2];
  uint64_t lmem_obuf[2];

  uint32_t M;
  uint32_t N;
  uint32_t K;
  uint32_t QBLK;
  uint32_t WTRANS;
  uint32_t QDIR;

  uint32_t status;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif // _COMMON_H_
