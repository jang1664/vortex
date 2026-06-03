#include "common.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

void kernel_hadamard(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t row = blockIdx.x;
  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;
  const uint32_t dim = arg->dim;
  const uint32_t padded_dim = arg->padded_dim;
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

  for (uint32_t stride = 1; stride < padded_dim; stride <<= 1) {
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

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher), arg);
}
