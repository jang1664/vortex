#include "common.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>

// Type aliases
using data_t = fp16_t;

///////////////////////////////////////////////////////////////////////////////
// Embedding (Row Gather) Kernel
//
// Formula: output[i, :] = table[indices[i], :]
//
// This implements the embedding lookup at the input of a transformer: each
// token id selects one row of the embedding table and that row is copied to
// the output. It is a pure indexed row copy - no arithmetic is performed.
//
// Strategy: flatten the (row i, element j) index space into a single
// grid-stride loop over num_indices * hidden_dim total elements, matching
// the style used by the SiLU kernel.
///////////////////////////////////////////////////////////////////////////////

void kernel_embedding(embedding_kernel_arg_t *__UNIFORM__ arg) {
  auto pIndices = reinterpret_cast<int32_t *>(arg->indices_addr);
  auto pTable   = reinterpret_cast<data_t *>(arg->table_addr);
  auto pOutput  = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t num_indices = arg->num_indices;
  const uint32_t hidden_dim  = arg->hidden_dim;
  const uint32_t vocab_size  = arg->vocab_size;
  const uint64_t total       = (uint64_t)num_indices * hidden_dim;

  uint32_t total_threads = gridDim.x * blockDim.x;
  uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint64_t e = thread_id; e < total; e += total_threads) {
    uint32_t i = (uint32_t)(e / hidden_dim);
    uint32_t j = (uint32_t)(e % hidden_dim);

    int32_t idx = pIndices[i];
    if ((uint32_t)idx >= vocab_size) {
      // Out-of-range index: skip this element to avoid an out-of-bounds
      // read from the embedding table.
      continue;
    }

    pOutput[(uint64_t)i * hidden_dim + j] = pTable[(uint64_t)idx * hidden_dim + j];
  }
}

///////////////////////////////////////////////////////////////////////////////
// Kernel dispatch
///////////////////////////////////////////////////////////////////////////////
void kernel_dispatcher(embedding_kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_EMBEDDING:
      kernel_embedding(arg);
      break;
    default:
      break;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main entry point
///////////////////////////////////////////////////////////////////////////////
static inline uint32_t effective_power_kernel_iterations(const embedding_kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(embedding_kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (embedding_kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                         (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
