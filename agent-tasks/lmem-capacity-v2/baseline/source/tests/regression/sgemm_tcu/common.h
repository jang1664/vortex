#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#ifndef NUM_THREADS
#define NUM_THREADS 8
#endif

#ifndef ITYPE
#define ITYPE fp16
#endif

#ifndef OTYPE
#define OTYPE fp16
#endif

#ifndef ACC_TYPE
#define ACC_TYPE fp32
#endif

#define SGEMM_TCU_VARIANT_BASELINE 0
#define SGEMM_TCU_VARIANT_B_COLMAJOR 1
#define SGEMM_TCU_VARIANT_LMEM 2
#define SGEMM_TCU_VARIANT_LMEM_B_COLMAJOR 3
#define SGEMM_TCU_VARIANT_KSTAGE4 4
#define SGEMM_TCU_VARIANT_KSTAGE4_N2 5
#define SGEMM_TCU_VARIANT_KSTAGE4_M2N2 6
#define SGEMM_TCU_VARIANT_KSTAGE4_M2N2_WIDE64 7
#define SGEMM_TCU_VARIANT_KSTAGE4_WIDE64 8

#ifndef SGEMM_TCU_VARIANT
#define SGEMM_TCU_VARIANT SGEMM_TCU_VARIANT_BASELINE
#endif

#ifndef SGEMM_TCU_WARPS_M
#define SGEMM_TCU_WARPS_M 2
#endif

#ifndef SGEMM_TCU_WARPS_N
#define SGEMM_TCU_WARPS_N 2
#endif

#ifndef SGEMM_TCU_FRAGS_M
#define SGEMM_TCU_FRAGS_M 1
#endif

#ifndef SGEMM_TCU_FRAGS_N
#define SGEMM_TCU_FRAGS_N 1
#endif

#ifndef SGEMM_TCU_K_STAGE_TILES
#define SGEMM_TCU_K_STAGE_TILES 1
#endif

#ifndef SGEMM_TCU_LOAD_BYTES
#define SGEMM_TCU_LOAD_BYTES 4
#endif

#define SGEMM_TCU_USE_LMEM \
  ((SGEMM_TCU_VARIANT == SGEMM_TCU_VARIANT_LMEM) || \
   (SGEMM_TCU_VARIANT == SGEMM_TCU_VARIANT_LMEM_B_COLMAJOR) || \
   (SGEMM_TCU_VARIANT >= SGEMM_TCU_VARIANT_KSTAGE4))

#define SGEMM_TCU_USE_B_COLMAJOR \
  ((SGEMM_TCU_VARIANT == SGEMM_TCU_VARIANT_B_COLMAJOR) || \
   (SGEMM_TCU_VARIANT == SGEMM_TCU_VARIANT_LMEM_B_COLMAJOR) || \
   (SGEMM_TCU_VARIANT >= SGEMM_TCU_VARIANT_KSTAGE4))

static inline uint32_t align_up_u32(uint32_t value, uint32_t alignment) {
  return ((value + alignment - 1) / alignment) * alignment;
}

typedef struct {
  uint32_t grid_dim[2];
  uint32_t block_dim[2];
  uint32_t M, N, K;
  uint64_t A_addr;
  uint64_t B_addr;
  uint64_t C_addr;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif
