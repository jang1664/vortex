#ifndef LLM_KERNEL_CONFIG_CHECK_H
#define LLM_KERNEL_CONFIG_CHECK_H

#include <VX_config.h>

// TCU-only/standalone C1 builds do not use the GEMM accelerator's MXU.
// Enforce the thread/MXU contract for builds that actually enable it.
#ifdef ENABLE_GEMM_ACCEL
static_assert(NUM_THREADS == MXU_ROW,
              "LLM kernels require NUM_THREADS == MXU_ROW");
static_assert(NUM_THREADS == MXU_COL,
              "LLM kernels require NUM_THREADS == MXU_COL");
#endif

#endif
