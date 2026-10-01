
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>

#ifndef NUM_THREADS
#define NUM_THREADS 4
#endif

#ifndef ITYPE
#define ITYPE fp16
#endif

#ifndef WTYPE
#define WTYPE int4
#endif

#ifndef OTYPE
#define OTYPE fp32
#endif

// GEMM descriptor register indices (0..43). Registers 40..42 are reserved by
// the naive backend so output progress has the same index as improve GEMM.
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
#define REG_LMEM_PSUM_LO        40
#define REG_LMEM_PSUM_HI        41
#define REG_OUTPUT_PROGRESS     43

#define GEMM_JOB_NUM_REGS32     44
#define GEMM_JOB_NUM_ENTRIES     4

// kernel status codes
#define MMIO_STATUS_INIT        0
#define MMIO_STATUS_OK          1
#define MMIO_STATUS_ALLOC_FAIL  2
#define MMIO_STATUS_WAIT_STUCK  3
#define MMIO_STATUS_BAD_EID     4

#define GEMM_FSM_MT 128
#define GEMM_FSM_NT 128
#define GEMM_FSM_KT 128

typedef struct {
  uint32_t grid_dim[2];
  uint32_t block_dim[2];

  uint32_t M;
  uint32_t N;
  uint32_t K;
  uint32_t QBLK;
  uint32_t WTRANS;
  uint32_t QDIR;

  uint64_t input_base;
  uint64_t weight_base;
  uint64_t output_base;
  uint64_t scale_base;
  uint64_t zp_base;

  uint64_t lmem_ibuf0_base;
  uint64_t lmem_ibuf1_base;
  uint64_t lmem_wbuf0_base;
  uint64_t lmem_wbuf1_base;
  uint64_t lmem_scbuf0_base;
  uint64_t lmem_scbuf1_base;
  uint64_t lmem_zpbuf0_base;
  uint64_t lmem_zpbuf1_base;
  uint64_t lmem_obuf_base;
  uint64_t lmem_psum_base;

  uint32_t status;
  uint32_t job_eid;
  uint32_t job_generation;
  uint32_t last_ctrl;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif // _COMMON_H_
