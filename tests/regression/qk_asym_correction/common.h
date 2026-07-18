#ifndef _QK_ASYM_CORRECTION_COMMON_H_
#define _QK_ASYM_CORRECTION_COMMON_H_

#include <stdint.h>

#define KERNEL_QK_ASYM_CORRECTION 0

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t scores_addr; // fp16 [M, N]
  uint64_t query_addr;  // fp16 [M, D]
  uint64_t scale_addr;  // fp16 [N]
  uint64_t zero_addr;   // fp16 [N], fractional SpinQuant zero point
  uint64_t output_addr; // fp16 [M, N]

  uint32_t M;
  uint32_t N;
  uint32_t D;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif
