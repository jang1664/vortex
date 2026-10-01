#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_MEAN 0
#define KERNEL_SUM  1
#define KERNEL_MAX  2
#define KERNEL_MIN  3

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  
  // Buffer addresses
  uint64_t input_addr;
  uint64_t output_addr;
  
  // Dimensions
  uint32_t batch_size;     // Number of rows
  uint32_t reduce_dim;     // Size of dimension to reduce (columns)
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
