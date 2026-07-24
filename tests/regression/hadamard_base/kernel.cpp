#include "../vector_common/fp16.h"
#include "common.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#ifndef HADAMARD_BASE_VARIANT_TAG
#define HADAMARD_BASE_VARIANT_TAG 0
#endif

void kernel_hadamard_base(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<const data_t *>(arg->input_addr);
  auto matrix = reinterpret_cast<const data_t *>(arg->matrix_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);
#if HADAMARD_BASE_VARIANT_TAG == 1
  const uint32_t total_columns = arg->rows * arg->width;
  const uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= total_columns)
    return;

  const uint32_t col = index % arg->width;
  const uint32_t row = index / arg->width;
  const uint64_t row_base =
      (uint64_t)row * arg->base_k * arg->width;
  uint32_t out_k = 0;
  for (; out_k + 3 < arg->base_k; out_k += 4) {
    const data_t* matrix0 = matrix + (uint64_t)(out_k + 0) * arg->base_k;
    const data_t* matrix1 = matrix + (uint64_t)(out_k + 1) * arg->base_k;
    const data_t* matrix2 = matrix + (uint64_t)(out_k + 2) * arg->base_k;
    const data_t* matrix3 = matrix + (uint64_t)(out_k + 3) * arg->base_k;
    float sum0 = 0.0f;
    float sum1 = 0.0f;
    float sum2 = 0.0f;
    float sum3 = 0.0f;
    for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
      const float value = fp16_to_float(
          input[row_base + (uint64_t)in_k * arg->width + col]);
      sum0 += fp16_to_float(matrix0[in_k]) * value;
      sum1 += fp16_to_float(matrix1[in_k]) * value;
      sum2 += fp16_to_float(matrix2[in_k]) * value;
      sum3 += fp16_to_float(matrix3[in_k]) * value;
    }
    output[row_base + (uint64_t)(out_k + 0) * arg->width + col] =
        float_to_fp16(sum0);
    output[row_base + (uint64_t)(out_k + 1) * arg->width + col] =
        float_to_fp16(sum1);
    output[row_base + (uint64_t)(out_k + 2) * arg->width + col] =
        float_to_fp16(sum2);
    output[row_base + (uint64_t)(out_k + 3) * arg->width + col] =
        float_to_fp16(sum3);
  }
  for (; out_k < arg->base_k; ++out_k) {
    const data_t* matrix_row =
        matrix + (uint64_t)out_k * arg->base_k;
    float sum = 0.0f;
    for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
      const float value = fp16_to_float(
          input[row_base + (uint64_t)in_k * arg->width + col]);
      sum += fp16_to_float(matrix_row[in_k]) * value;
    }
    output[row_base + (uint64_t)out_k * arg->width + col] =
        float_to_fp16(sum);
  }
#else
  const uint32_t total = arg->rows * arg->base_k * arg->width;
  const uint32_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= total)
    return;

  const uint32_t col = index % arg->width;
  const uint32_t out_k = (index / arg->width) % arg->base_k;
  const uint32_t row = index / (arg->width * arg->base_k);
  const uint64_t row_base = (uint64_t)row * arg->base_k * arg->width;
  float sum = 0.0f;
  for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
    const float coefficient =
        fp16_to_float(matrix[(uint64_t)out_k * arg->base_k + in_k]);
    const float value =
        fp16_to_float(input[row_base + (uint64_t)in_k * arg->width + col]);
    sum += coefficient * value;
  }
  output[index] = float_to_fp16(sum);
#endif
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_HADAMARD_BASE)
    kernel_hadamard_base(arg);
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat =
      (arg->power_kernel_iterations == 0) ? 1 : arg->power_kernel_iterations;
  for (uint32_t iteration = 0; iteration < repeat; ++iteration)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
