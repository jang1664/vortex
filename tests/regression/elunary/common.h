#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Unary operation types
#define KERNEL_RSQRT  0
#define KERNEL_SIN    1
#define KERNEL_COS    2
#define KERNEL_EXP    3
#define KERNEL_LOG    4
#define KERNEL_NEG    5
#define KERNEL_ABS    6
#define KERNEL_SQRT   7

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
} kernel_arg_t;

#endif // _COMMON_H_
