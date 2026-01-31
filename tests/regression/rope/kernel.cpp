#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <math.h>

// Type aliases
using data_t = float;  // fp32 for now, can be changed to fp16

///////////////////////////////////////////////////////////////////////////////
// RoPE (Rotary Position Embedding) Kernel
// 
// Formula: For each pair (x0, x1):
//   y0 = x0 * cos(theta) - x1 * sin(theta)
//   y1 = x0 * sin(theta) + x1 * cos(theta)
//
// Strategy:
// - Parallelize across (batch, seq, head, pair) dimensions
// - Each thread processes one or more pairs
// - cos/sin are precomputed on host
///////////////////////////////////////////////////////////////////////////////

void kernel_rope(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  auto pCos = reinterpret_cast<data_t *>(arg->cos_addr);
  auto pSin = reinterpret_cast<data_t *>(arg->sin_addr);
  
  uint32_t batch_size = arg->batch_size;
  uint32_t seq_len = arg->seq_len;
  uint32_t num_heads = arg->num_heads;
  uint32_t head_dim = arg->head_dim;
  uint32_t pos_offset = arg->pos_offset;
  
  uint32_t half_dim = head_dim / 2;  // Number of pairs
  
  // Total number of pairs to process
  uint32_t total_pairs = batch_size * seq_len * num_heads * half_dim;
  
  // Grid-stride loop
  uint32_t total_threads = gridDim.x * gridDim.y * blockDim.x * blockDim.y;
  uint32_t thread_id = (blockIdx.y * gridDim.x + blockIdx.x) * (blockDim.x * blockDim.y) +
                       (threadIdx.y * blockDim.x + threadIdx.x);
  
  for (uint32_t pair_idx = thread_id; pair_idx < total_pairs; pair_idx += total_threads) {
    // Decode indices: [batch, seq, head, pair]
    uint32_t b = pair_idx / (seq_len * num_heads * half_dim);
    uint32_t remainder = pair_idx % (seq_len * num_heads * half_dim);
    uint32_t s = remainder / (num_heads * half_dim);
    remainder = remainder % (num_heads * half_dim);
    uint32_t h = remainder / half_dim;
    uint32_t p = remainder % half_dim;
    
    // Position in sequence (with offset for incremental decoding)
    uint32_t pos = s + pos_offset;
    
    // Load cos and sin for this position and pair
    uint32_t freq_idx = pos * half_dim + p;
    float cos_val = pCos[freq_idx];
    float sin_val = pSin[freq_idx];
    
    // Load the pair of values from input
    uint32_t base_idx = ((b * seq_len + s) * num_heads + h) * head_dim;
    uint32_t idx0 = base_idx + p;
    uint32_t idx1 = base_idx + p + half_dim;
    
    float x0 = pInput[idx0];
    float x1 = pInput[idx1];
    
    // Apply rotation
    float y0 = x0 * cos_val - x1 * sin_val;
    float y1 = x0 * sin_val + x1 * cos_val;
    
    // Store results
    pOutput[idx0] = y0;
    pOutput[idx1] = y1;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_ROPE:
      kernel_rope(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
}
