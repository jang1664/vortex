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
  const uint32_t launch_rows =
      arg->padded_row_launch != 0 ? arg->m_pad : arg->rows;
  const uint32_t matrix_idx = physical_row / launch_rows;
  const uint32_t row = physical_row - matrix_idx * launch_rows;
  const bool zero_padding = arg->base_k == 0;
  const uint32_t scratch_dim = zero_padding ? arg->width : arg->dim;
  const uint32_t butterfly_width = arg->width;
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
      __local_mem(scratch_dim * sizeof(float)));
  const uint64_t input_matrix_base =
      (uint64_t)matrix_idx
      * (arg->input_layout == HADAMARD_INPUT_GEMM_A_TILED
             ? arg->m_pad : arg->rows)
      * arg->dim;
  for (uint32_t column = tid; column < scratch_dim; column += blockDim.x) {
    if (column >= arg->dim) {
      scratch[column] = 0.0f;
    } else if (arg->input_layout == HADAMARD_INPUT_GEMM_A_TILED) {
      const uint64_t offset = input_matrix_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      scratch[column] = fp16_to_float(input[offset]);
    } else {
      scratch[column] =
          fp16_to_float(input[input_matrix_base + (uint64_t)row * arg->dim
                              + column]);
    }
  }
  __syncthreads();

  for (uint32_t stride = 1; stride < butterfly_width; stride <<= 1) {
    const uint32_t pairs = scratch_dim >> 1;
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

  // The standalone factorized path materializes the scaled butterfly output
  // as fp16 before the base transform. Preserve that rounding boundary once
  // per intermediate element instead of repeating the same float -> fp16 ->
  // float conversion for every out_k.
  if (!zero_padding && arg->base_k > 1) {
    for (uint32_t column = tid; column < scratch_dim;
         column += blockDim.x) {
      scratch[column] = fp16_to_float(
          float_to_fp16(scratch[column] * arg->inv_sqrt_dim));
    }
    __syncthreads();
  }

  if (zero_padding || arg->base_k == 1) {
    for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
      const float transformed = scratch[column] * arg->inv_sqrt_dim;
      const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      output[offset] = float_to_fp16(transformed);
    }
    return;
  }

  // Keep a thread on one butterfly column while producing four base-transform
  // outputs. Each intermediate scratch value is then loaded once and reused
  // by four accumulators instead of being loaded once per out_k.
  for (uint32_t width_col = tid; width_col < arg->width;
       width_col += blockDim.x) {
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
        const float intermediate =
            scratch[(uint64_t)in_k * arg->width + width_col];
        sum0 += fp16_to_float(matrix0[in_k]) * intermediate;
        sum1 += fp16_to_float(matrix1[in_k]) * intermediate;
        sum2 += fp16_to_float(matrix2[in_k]) * intermediate;
        sum3 += fp16_to_float(matrix3[in_k]) * intermediate;
      }
      const uint32_t column0 = (out_k + 0) * arg->width + width_col;
      const uint32_t column1 = (out_k + 1) * arg->width + width_col;
      const uint32_t column2 = (out_k + 2) * arg->width + width_col;
      const uint32_t column3 = (out_k + 3) * arg->width + width_col;
      output[output_base + gemm_a_tiled_elem_offset(
          row, column0, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum0);
      output[output_base + gemm_a_tiled_elem_offset(
          row, column1, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum1);
      output[output_base + gemm_a_tiled_elem_offset(
          row, column2, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum2);
      output[output_base + gemm_a_tiled_elem_offset(
          row, column3, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum3);
    }
    for (; out_k < arg->base_k; ++out_k) {
      const data_t* matrix_row =
          matrix + (uint64_t)out_k * arg->base_k;
      float sum = 0.0f;
      for (uint32_t in_k = 0; in_k < arg->base_k; ++in_k) {
        sum += fp16_to_float(matrix_row[in_k])
            * scratch[(uint64_t)in_k * arg->width + width_col];
      }
      const uint32_t column = out_k * arg->width + width_col;
      output[output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum);
    }
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
