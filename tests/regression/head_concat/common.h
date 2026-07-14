#ifndef _HEAD_CONCAT_COMMON_H_
#define _HEAD_CONCAT_COMMON_H_

#include <stdint.h>

#define KERNEL_HEAD_CONCAT 0

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t input_addr;   // fp16 row-major [batch, heads, seq, headdim]
  uint64_t output_addr;  // fp16 row-major [batch, seq, heads * headdim]

  uint32_t batch;
  uint32_t seq;
  uint32_t heads;
  uint32_t headdim;
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _HEAD_CONCAT_COMMON_H_
