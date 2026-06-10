#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#define KERNEL_SOFTMAX 0

typedef struct {
  // Kernel configuration
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  
  // Buffer addresses
  uint64_t input_addr;
  uint64_t output_addr;
  uint64_t mask_addr;  // Optional: for causal masking
  
  // Dimensions
  // Input/Output shape: [batch_size, num_heads, seq_len_q, seq_len_k]
  // Softmax applied over seq_len_k dimension for each (batch, head, query_pos)
  uint32_t batch_size;
  uint32_t num_heads;
  uint32_t seq_len_q;  // Query sequence length
  uint32_t seq_len_k;  // Key sequence length
  uint32_t row_pitch_bytes; // Physical HBM distance between logical rows

  // Options
  uint32_t use_mask;   // 0: no mask, 1: apply causal mask
  float scale;         // Scaling factor (e.g., 1/sqrt(d_k) for attention)
} kernel_arg_t;

#endif // _COMMON_H_
