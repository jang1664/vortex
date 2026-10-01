#include "common.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

// Returns arg->stop_stride, defaulting to a full transform (padded_dim) when
// the host leaves the field zero-initialized. See common.h for the contract.
static inline uint32_t effective_stop_stride(const kernel_arg_t* arg) {
  return (arg->stop_stride == 0u) ? arg->padded_dim : arg->stop_stride;
}

// Mixed-radix FWHT butterfly (see common.h for the full K==1 vs K>1
// contract). This kernel always performs the recursive-doubling butterfly
// stages (stride = 1, 2, 4, ...), but STOPS as soon as stride reaches
// stop_stride instead of always continuing to stride == padded_dim/2.
//   - stop_stride == padded_dim   -> all log2(padded_dim) stages run, i.e.
//     the FULL Hadamard transform (identical to the original kernel; this
//     is the K == 1 case).
//   - stop_stride == padded_dim/K -> only the first log2(padded_dim/K)
//     stages run, leaving K independently-transformed contiguous blocks of
//     size padded_dim/K un-combined. The device does NOT multiply these
//     blocks by the KxK base matrix; that step is delegated to the host
//     (e.g. a native `bmm` over the reshaped [..., K, padded_dim/K] output).
void kernel_hadamard(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t row = blockIdx.x;
  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;
  const uint32_t dim = arg->dim;
  const uint32_t padded_dim = arg->padded_dim;
  const uint32_t stop_stride = effective_stop_stride(arg);
  const float scale = arg->inv_sqrt_dim;

  if (row >= arg->rows) {
    return;
  }

  auto buf = reinterpret_cast<float *>(__local_mem(padded_dim * sizeof(float)));
  const uint32_t row_offset = row * dim;

  for (uint32_t i = tid; i < padded_dim; i += block_size) {
    buf[i] = (i < dim) ? fp16_to_float(input[row_offset + i]) : 0.0f;
  }
  __syncthreads();

  for (uint32_t stride = 1; stride < stop_stride; stride <<= 1) {
    const uint32_t pairs = padded_dim >> 1;
    for (uint32_t pair = tid; pair < pairs; pair += block_size) {
      const uint32_t base = (pair / stride) * (stride << 1) + (pair % stride);
      const float a = buf[base];
      const float b = buf[base + stride];
      buf[base] = a + b;
      buf[base + stride] = a - b;
    }
    __syncthreads();
  }

  for (uint32_t i = tid; i < dim; i += block_size) {
    output[row_offset + i] = float_to_fp16(buf[i] * scale);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_HADAMARD:
      kernel_hadamard(arg);
      break;
    default:
      break;
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
