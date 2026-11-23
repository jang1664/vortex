#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>
#include <VX_config.h>
#include <VX_types.h>

// Kernel IDs
#define KERNEL_RMSNORM  0
#define KERNEL_QK_NORM_TILED 1
#include "../layout_fused_common/layout_fused_layouts.h"

#ifndef RMSNORM_VARIANT_TAG
#define RMSNORM_VARIANT_TAG 0
#endif

static inline uint32_t rmsnorm_threads_per_block(
    uint32_t total_tokens,
    uint32_t num_warps,
    uint32_t num_threads) {
  uint32_t max_threads = num_warps * num_threads;
  if (max_threads > 256u)
    max_threads = 256u;

  uint32_t reduction_threads = 1u;
  while ((reduction_threads << 1) <= max_threads)
    reduction_threads <<= 1;

#if RMSNORM_VARIANT_TAG == 1
  return (total_tokens < num_warps) ? reduction_threads : num_threads;
#else
  (void)total_tokens;
  return reduction_threads;
#endif
}

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
  
  uint32_t power_kernel_iterations;
  uint32_t tiled_heads;
} kernel_arg_t;
// The projection stores one GEMM-C matrix, with all heads in its N axis.
static inline uint32_t qk_padded_rows(uint32_t tokens, uint32_t heads) {
  return ((tokens / heads + 7u) / 8u) * 8u;
}
static inline uint64_t qk_tiled_offset(uint32_t token, uint32_t channel,
                                      uint32_t heads, uint32_t dim, uint32_t padded_rows) {
  return gemm_c_tiled_elem_offset(token / heads, (token % heads) * dim + channel,
                                 padded_rows, heads * dim, 7u, __builtin_ctz(MXU_COL));
}
#endif // _COMMON_H_
