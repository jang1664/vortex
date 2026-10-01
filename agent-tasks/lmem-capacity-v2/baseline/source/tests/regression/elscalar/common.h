#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Binary element-wise operations with scalar
#define KERNEL_POW_SCALAR 0  // x^n where n is scalar
#define KERNEL_MUL_SCALAR 1  // x*n where n is scalar
#define KERNEL_ADD_SCALAR 2  // x+n where n is scalar

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  
  // Buffer addresses
  uint64_t input_addr;
  uint64_t output_addr;
  
  // Scalar value (as float bits, reinterpreted)
  float scalar;
  
  // Dimensions
  uint32_t size;  // Total number of elements
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
