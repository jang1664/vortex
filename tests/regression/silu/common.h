#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_SILU 0

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  
  // Buffer addresses
  uint64_t input_addr;
  uint64_t output_addr;
  
  // Dimensions
  uint32_t size;  // Total number of elements
  uint32_t M;     // Logical rows for M x K traversal
  uint32_t K;     // Logical row width for M x K traversal
} kernel_arg_t;

#endif // _COMMON_H_
