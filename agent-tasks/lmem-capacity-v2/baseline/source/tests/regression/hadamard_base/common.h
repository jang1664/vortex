#ifndef _HADAMARD_BASE_COMMON_H_
#define _HADAMARD_BASE_COMMON_H_

#include <stdint.h>

#define KERNEL_HADAMARD_BASE 0

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t matrix_addr;
  uint64_t output_addr;
  uint32_t rows;
  uint32_t base_k;
  uint32_t width;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif
