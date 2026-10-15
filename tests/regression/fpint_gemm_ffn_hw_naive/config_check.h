#ifndef NAIVE_GEMM_CONFIG_CHECK_H
#define NAIVE_GEMM_CONFIG_CHECK_H

#include <VX_config.h>

#ifdef GEMM_NAIVE_FP16_ENABLE
// This MMIO driver does not map SIMT lanes onto the FPFP arithmetic array.
// The naive operand DMA transfers native 8-byte beats.
static_assert(FPFP_MXU_ROW > 0 && (FPFP_MXU_ROW & (FPFP_MXU_ROW - 1)) == 0,
              "FPFP_MXU_ROW must be a positive power of two");
static_assert(FPFP_MXU_COL > 0 && (FPFP_MXU_COL & (FPFP_MXU_COL - 1)) == 0,
              "FPFP_MXU_COL must be a positive power of two");
static_assert(FPFP_MXU_ROW * 2 >= 8 && (FPFP_MXU_ROW * 2) % 8 == 0,
              "FPFP input vector must contain whole 8-byte LMEM words (ROW >= 4)");
static_assert(FPFP_MXU_COL * 2 >= 8 && (FPFP_MXU_COL * 2) % 8 == 0,
              "FPFP output vector must contain whole 8-byte LMEM words (COL >= 4)");
static_assert(FPFP_MXU_ROW <= 128 && 128 % FPFP_MXU_ROW == 0
                  && FPFP_MXU_COL <= 128 && 128 % FPFP_MXU_COL == 0,
              "FPFP dimensions must divide the 128-element DMA tiles");
static_assert(FPFP_MXU_WLOAD_NUM > 0 && FPFP_MXU_ROW % FPFP_MXU_WLOAD_NUM == 0,
              "FPFP_MXU_WLOAD_NUM must divide FPFP_MXU_ROW");
static_assert(FPFP_MXU_ROW * 2 <= LMEM_NUM_PORTS * 8
                  && FPFP_MXU_COL * 2 <= LMEM_NUM_PORTS * 8
                  && FPFP_MXU_COL * FPFP_MXU_WLOAD_NUM * 2 <= LMEM_NUM_PORTS * 8,
              "FPFP operand vectors and weight groups must fit the LMEM ports");
static_assert(GEMM_SHARED_ACC_COL <= LMEM_NUM_PORTS
                  && (LMEM_NUM_PORTS & (LMEM_NUM_PORTS - 1)) == 0,
              "Shared ACC transport requires power-of-two ports covering physical COL");
#endif
#ifdef GEMM_NAIVE_ENABLE
// Preserve the existing FPINT and vector-kernel configuration contract.
#include "../vector_common/config_check.h"
#endif

#endif
