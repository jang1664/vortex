#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_EMBEDDING 0

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  // Buffer addresses
  uint64_t indices_addr;  // int32 token ids [num_indices]
  uint64_t table_addr;    // fp16 embedding table [vocab_size, hidden_dim]
  uint64_t output_addr;   // fp16 gathered rows [num_indices, hidden_dim]

  // Dimensions
  uint32_t num_indices;   // N: number of rows to gather (number of tokens)
  uint32_t hidden_dim;    // K: embedding row width
  uint32_t vocab_size;    // number of rows in the embedding table

  uint32_t power_kernel_iterations;
} embedding_kernel_arg_t;
#endif // _COMMON_H_
