#ifndef _FLASH_ATTN_COMMON_H_
#define _FLASH_ATTN_COMMON_H_

#include <stdint.h>
#include <VX_config.h>

#ifdef GEMM_NAIVE
#error "flash_attn requires improve GEMM output-progress visibility"
#endif

#if !GEMM_ACCEL_ENABLED
#error "flash_attn requires ENABLE_GEMM_ACCEL"
#endif

#define FLASH_DMA_MT 128u
#define FLASH_DMA_NT 128u
#define FLASH_DMA_KT 128u
#define FLASH_QBLK    32u

#define FLASH_MXU_KT MXU_ROW
#define FLASH_MXU_NT MXU_COL

#define REG_CONTROL             0u
#define REG_INPUT_BASE_LO       1u
#define REG_WEIGHT_BASE_LO      3u
#define REG_OUTPUT_BASE_LO      5u
#define REG_SCALE_BASE_LO       7u
#define REG_ZP_BASE_LO          9u
#define REG_LMEM_IBUF0_LO      11u
#define REG_LMEM_IBUF1_LO      13u
#define REG_LMEM_WBUF0_LO      15u
#define REG_LMEM_WBUF1_LO      17u
#define REG_LMEM_SCBUF0_LO     19u
#define REG_LMEM_SCBUF1_LO     21u
#define REG_LMEM_ZPBUF0_LO     23u
#define REG_LMEM_ZPBUF1_LO     25u
#define REG_LMEM_OBUF_LO       27u
#define REG_M_ORIG             29u
#define REG_N_ORIG             30u
#define REG_K_ORIG             31u
#define REG_QBLK_ORIG          32u
#define REG_M_TARGET           33u
#define REG_N_TARGET           34u
#define REG_K_TARGET           35u
#define REG_M_START            36u
#define REG_N_START            37u
#define REG_WTRANS             38u
#define REG_QDIR               39u
#define REG_LOG2_DMA_MT        40u
#define REG_LOG2_DMA_KT        41u
#define REG_LOG2_DMA_NT        42u
#define REG_OUTPUT_PROGRESS    43u

#define GEMM_JOB_NUM_REGS32  44u
#define GEMM_JOB_NUM_ENTRIES  4u

#define FLASH_STATUS_INIT              0u
#define FLASH_STATUS_OK                1u
#define FLASH_STATUS_ALLOC_FAIL        2u
#define FLASH_STATUS_PROGRESS_TIMEOUT  3u
#define FLASH_STATUS_JOB_TIMEOUT       4u
#define FLASH_STATUS_BAD_DEVICE        6u
#define FLASH_STATUS_SRAM_DMA          7u
#define FLASH_STATUS_RESIDENT_JOB      8u

#include <vx_flash_attention.h>
typedef vx_flash_attention_args_t kernel_arg_t;

#endif
