#include "common.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#if HADAMARD_VARIANT_TAG == 2
static inline uint32_t float_to_bits(float value) {
  union {
    float f;
    uint32_t u;
  } bits = {value};
  return bits.u;
}

static inline float bits_to_float(uint32_t value) {
  union {
    uint32_t u;
    float f;
  } bits = {value};
  return bits.f;
}

static inline float shuffle_butterfly(float value, uint32_t stride) {
  return bits_to_float(static_cast<uint32_t>(
      vx_shfl_bfly(float_to_bits(value), stride, 31, 0)));
}

static inline float butterfly_lane(float value, uint32_t lane,
                                   uint32_t stride) {
  const float other = shuffle_butterfly(value, stride);
  return (lane & stride) ? (other - value) : (value + other);
}

static inline void kernel_hadamard_r3_shuffle(
    const data_t* input, data_t* output, uint32_t row, float scale) {
  const uint32_t lane = threadIdx.x;
  const uint64_t row_offset = static_cast<uint64_t>(row) * 128u;

  float value0 = fp16_to_float(input[row_offset + lane]);
  float value1 = fp16_to_float(input[row_offset + lane + 32u]);
  float value2 = fp16_to_float(input[row_offset + lane + 64u]);
  float value3 = fp16_to_float(input[row_offset + lane + 96u]);

  for (uint32_t stride = 1; stride < 32u; stride <<= 1) {
    value0 = butterfly_lane(value0, lane, stride);
    value1 = butterfly_lane(value1, lane, stride);
    value2 = butterfly_lane(value2, lane, stride);
    value3 = butterfly_lane(value3, lane, stride);
  }

  float a = value0;
  float b = value1;
  value0 = a + b;
  value1 = a - b;
  a = value2;
  b = value3;
  value2 = a + b;
  value3 = a - b;

  a = value0;
  b = value2;
  value0 = a + b;
  value2 = a - b;
  a = value1;
  b = value3;
  value1 = a + b;
  value3 = a - b;

  output[row_offset + lane] = float_to_fp16(value0 * scale);
  output[row_offset + lane + 32u] = float_to_fp16(value1 * scale);
  output[row_offset + lane + 64u] = float_to_fp16(value2 * scale);
  output[row_offset + lane + 96u] = float_to_fp16(value3 * scale);
}
#endif

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

#if HADAMARD_VARIANT_TAG == 2
  if (arg->base_k == 1u && dim == 128u && block_size == 32u) {
    for (uint32_t persistent_row = row; persistent_row < arg->rows;
         persistent_row += gridDim.x) {
      kernel_hadamard_r3_shuffle(
          input, output, persistent_row, scale);
    }
    return;
  }
#endif

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
