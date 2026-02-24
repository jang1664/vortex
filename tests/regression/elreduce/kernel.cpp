#include "common.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <cmath>
#include <cfloat>

// Type aliases
using data_t = float;

///////////////////////////////////////////////////////////////////////////////
// Reduction Kernels (per-row reductions)
// 
// These implement reductions along the last dimension (keepdim=True style)
// Input: [batch_size, reduce_dim]
// Output: [batch_size, 1]
// 
// Critical for transformers:
// - mean: RMSNorm variance computation
// - sum: Softmax normalization
// - max: Softmax numerical stability
///////////////////////////////////////////////////////////////////////////////

void kernel_mean(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t batch_size = arg->batch_size;
  uint32_t reduce_dim = arg->reduce_dim;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  // Each thread handles one or more rows
  for (uint32_t row = thread_id; row < batch_size; row += total_threads) {
    float sum = 0.0f;
    const float* row_ptr = pInput + row * reduce_dim;
    
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      sum += row_ptr[col];
    }
    
    pOutput[row] = sum / static_cast<float>(reduce_dim);
  }
}

void kernel_sum(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t batch_size = arg->batch_size;
  uint32_t reduce_dim = arg->reduce_dim;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t row = thread_id; row < batch_size; row += total_threads) {
    float sum = 0.0f;
    const float* row_ptr = pInput + row * reduce_dim;
    
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      sum += row_ptr[col];
    }
    
    pOutput[row] = sum;
  }
}

void kernel_max(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t batch_size = arg->batch_size;
  uint32_t reduce_dim = arg->reduce_dim;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t row = thread_id; row < batch_size; row += total_threads) {
    float max_val = -FLT_MAX;
    const float* row_ptr = pInput + row * reduce_dim;
    
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      if (row_ptr[col] > max_val) {
        max_val = row_ptr[col];
      }
    }
    
    pOutput[row] = max_val;
  }
}

void kernel_min(kernel_arg_t *__UNIFORM__ arg) {
  auto pInput = reinterpret_cast<data_t *>(arg->input_addr);
  auto pOutput = reinterpret_cast<data_t *>(arg->output_addr);
  uint32_t batch_size = arg->batch_size;
  uint32_t reduce_dim = arg->reduce_dim;
  
  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  
  for (uint32_t row = thread_id; row < batch_size; row += total_threads) {
    float min_val = FLT_MAX;
    const float* row_ptr = pInput + row * reduce_dim;
    
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      if (row_ptr[col] < min_val) {
        min_val = row_ptr[col];
      }
    }
    
    pOutput[row] = min_val;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_MEAN: kernel_mean(arg); break;
    case KERNEL_SUM:  kernel_sum(arg);  break;
    case KERNEL_MAX:  kernel_max(arg);  break;
    case KERNEL_MIN:  kernel_min(arg);  break;
    default: break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher, arg);
}
