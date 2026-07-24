#include "common.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

static inline uint32_t effective_stop_stride(const kernel_arg_t* arg) {
  return arg->stop_stride == 0u ? arg->padded_dim : arg->stop_stride;
}

void kernel_hadamard(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<const data_t *>(arg->input_addr);
  auto matrix = reinterpret_cast<const data_t *>(arg->matrix_addr);
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

  if (arg->base_k > 1) {
    // Match the former two-kernel boundary once, then reuse each rounded
    // butterfly intermediate across four base-transform outputs.
    for (uint32_t i = tid; i < dim; i += block_size) {
      buf[i] = fp16_to_float(float_to_fp16(buf[i] * scale));
    }
    __syncthreads();

    for (uint32_t width_col = tid; width_col < arg->width;
         width_col += block_size) {
      uint32_t out_k = 0;
      for (; out_k + 3 < arg->base_k; out_k += 4) {
        const data_t* matrix0 =
            matrix + (uint64_t)(out_k + 0) * arg->base_k;
        const data_t* matrix1 =
            matrix + (uint64_t)(out_k + 1) * arg->base_k;
        const data_t* matrix2 =
            matrix + (uint64_t)(out_k + 2) * arg->base_k;
        const data_t* matrix3 =
            matrix + (uint64_t)(out_k + 3) * arg->base_k;
        float sum0 = 0.0f;
        float sum1 = 0.0f;
        float sum2 = 0.0f;
        float sum3 = 0.0f;
        for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
          const float intermediate =
              buf[(uint64_t)in_k * arg->width + width_col];
          sum0 += fp16_to_float(matrix0[in_k]) * intermediate;
          sum1 += fp16_to_float(matrix1[in_k]) * intermediate;
          sum2 += fp16_to_float(matrix2[in_k]) * intermediate;
          sum3 += fp16_to_float(matrix3[in_k]) * intermediate;
        }
        output[row_offset + (out_k + 0) * arg->width + width_col] =
            float_to_fp16(sum0);
        output[row_offset + (out_k + 1) * arg->width + width_col] =
            float_to_fp16(sum1);
        output[row_offset + (out_k + 2) * arg->width + width_col] =
            float_to_fp16(sum2);
        output[row_offset + (out_k + 3) * arg->width + width_col] =
            float_to_fp16(sum3);
      }
      for (; out_k < arg->base_k; ++out_k) {
        const data_t* matrix_row =
            matrix + (uint64_t)out_k * arg->base_k;
        float sum = 0.0f;
        for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
          sum += fp16_to_float(matrix_row[in_k])
              * buf[(uint64_t)in_k * arg->width + width_col];
        }
        output[row_offset + out_k * arg->width + width_col] =
            float_to_fp16(sum);
      }
    }
    return;
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
