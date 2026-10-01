#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>
#include <VX_types.h>

// Kernel IDs
#define KERNEL_ROPE  0

// Kernel arguments structure
typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];     // Grid dimensions
  uint32_t block_dim[3];    // Block dimensions
  
  // Input/Output pointers
  uint64_t input_addr;      // Input Q or K [batch, seq_len, num_heads, head_dim]
  uint64_t output_addr;     // Output [batch, seq_len, num_heads, head_dim]
  uint64_t cos_addr;        // Precomputed cos [max_seq_len, head_dim/2]
  uint64_t sin_addr;        // Precomputed sin [max_seq_len, head_dim/2]
  
  // Tensor dimensions
  uint32_t batch_size;      // Batch size
  uint32_t seq_len;         // Sequence length
  uint32_t num_heads;       // Number of attention heads
  uint32_t head_dim;        // Head dimension (must be even)
  
  // RoPE parameters
  uint32_t pos_offset;      // Position offset for incremental decoding
  
  uint32_t power_kernel_iterations;
} kernel_arg_t;
#endif // _COMMON_H_
