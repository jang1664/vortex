#ifndef _HADAMARD_COMMON_H_
#define _HADAMARD_COMMON_H_

#include <stdint.h>

#define KERNEL_HADAMARD 0

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;
  uint64_t output_addr;

  uint32_t rows;
  uint32_t dim;
  uint32_t padded_dim;
  float inv_sqrt_dim;
} kernel_arg_t;

#endif // _HADAMARD_COMMON_H_
