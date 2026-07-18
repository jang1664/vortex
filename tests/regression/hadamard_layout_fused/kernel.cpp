#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

void kernel_hadamard_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<const data_t *>(arg->input_addr);
  auto matrix = reinterpret_cast<const data_t *>(arg->matrix_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t physical_row = blockIdx.x;
  const uint32_t tid = threadIdx.x;
  const uint32_t matrix_idx = physical_row / arg->m_pad;
  const uint32_t row = physical_row - matrix_idx * arg->m_pad;
  if (matrix_idx >= arg->matrix_count)
    return;

  const uint64_t output_base =
      (uint64_t)matrix_idx * arg->m_pad * arg->dim;
  if (row >= arg->rows) {
    for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
      const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      output[offset] = 0;
    }
    return;
  }

  auto scratch = reinterpret_cast<float *>(
      __local_mem(arg->dim * sizeof(float)));
  const uint64_t input_base =
      ((uint64_t)matrix_idx * arg->rows + row) * arg->dim;
  for (uint32_t column = tid; column < arg->dim; column += blockDim.x)
    scratch[column] = fp16_to_float(input[input_base + column]);
  __syncthreads();

  for (uint32_t stride = 1; stride < arg->width; stride <<= 1) {
    const uint32_t pairs = arg->dim >> 1;
    for (uint32_t pair = tid; pair < pairs; pair += blockDim.x) {
      const uint32_t base =
          (pair / stride) * (stride << 1) + (pair % stride);
      const float a = scratch[base];
      const float b = scratch[base + stride];
      scratch[base] = a + b;
      scratch[base + stride] = a - b;
    }
    __syncthreads();
  }

  for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
    float transformed;
    if (arg->base_k == 1) {
      transformed = scratch[column] * arg->inv_sqrt_dim;
    } else {
      const uint32_t out_k = column / arg->width;
      const uint32_t width_col = column - out_k * arg->width;
      transformed = 0.0f;
      for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
        const float coefficient = fp16_to_float(
            matrix[(uint64_t)out_k * arg->base_k + in_k]);
        // Preserve the standalone butterfly -> fp16 -> base-matmul rounding
        // boundary while eliminating its intermediate global-memory buffer.
        const float intermediate = fp16_to_float(float_to_fp16(
            scratch[(uint64_t)in_k * arg->width + width_col]
            * arg->inv_sqrt_dim));
        transformed += coefficient * intermediate;
      }
    }
    const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
        row, column, arg->m_pad, arg->dim,
        arg->log2_mt, arg->log2_mxu_kt);
    output[offset] = float_to_fp16(transformed);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_HADAMARD_LAYOUT_FUSED)
    kernel_hadamard_layout_fused(arg);
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = arg->power_kernel_iterations == 0
      ? 1 : arg->power_kernel_iterations;
  for (uint32_t iteration = 0; iteration < repeat; ++iteration)
    kernel_dispatcher(arg);
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
