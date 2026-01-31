#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>
#include <VX_types.h>

// Kernel IDs
#define KERNEL_RMSNORM  0

// Kernel arguments structure
typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];     // Grid dimensions
  uint32_t block_dim[3];    // Block dimensions
  
  // Input/Output pointers
  uint64_t input_addr;      // Input tensor [batch, seq_len, hidden_dim]
  uint64_t output_addr;     // Output tensor [batch, seq_len, hidden_dim]
  uint64_t gamma_addr;      // Gamma weights [hidden_dim]
  
  // Tensor dimensions
  uint32_t batch_size;      // Batch size
  uint32_t seq_len;         // Sequence length
  uint32_t hidden_dim;      // Hidden dimension
  
  // RMSNorm parameters
  float eps;                // Epsilon for numerical stability (typically 1e-6)
  
} kernel_arg_t;

#endif // _COMMON_H_
