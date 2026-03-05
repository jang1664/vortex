#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_ELSUB 0

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  
  // Buffer addresses
  uint64_t input_a_addr;
  uint64_t input_b_addr;
  uint64_t output_addr;
  
  // Dimensions
  uint32_t size;  // Total number of elements
} kernel_arg_t;

#endif // _COMMON_H_
