#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"

#include <vx_intrinsics.h>
#include <vx_spawn.h>

using data_t = fp16_t;

#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
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

static inline uint32_t tiled_row_count(uint32_t row, uint32_t m_pad) {
  const uint32_t tile_start = row & ~(HADAMARD_TILE_DMA_MT - 1u);
  return min_u32(m_pad - tile_start, HADAMARD_TILE_DMA_MT);
}

static inline uint64_t tiled_row_base(uint64_t matrix_base, uint32_t row,
                                      uint32_t dim) {
  const uint32_t tile_index = row >> 7;
  const uint32_t row_in_tile = row & (HADAMARD_TILE_DMA_MT - 1u);
  return matrix_base
       + static_cast<uint64_t>(tile_index) * HADAMARD_TILE_DMA_MT * dim
       + static_cast<uint64_t>(row_in_tile) * HADAMARD_TILE_MXU_KT;
}

static inline uint64_t tiled_column_offset(uint32_t column,
                                           uint64_t group_stride) {
  return static_cast<uint64_t>(column >> 5) * group_stride
       + (column & (HADAMARD_TILE_MXU_KT - 1u));
}

static inline void kernel_hadamard_r3_shuffle_incremental(
    const data_t* input, data_t* output, const kernel_arg_t* arg,
    uint32_t matrix_idx, uint32_t row, uint64_t output_base) {
  const uint32_t lane = threadIdx.x;
  const uint64_t input_base =
      (static_cast<uint64_t>(matrix_idx) * arg->rows + row) * 128u;

  float value0 = fp16_to_float(input[input_base + lane]);
  float value1 = fp16_to_float(input[input_base + lane + 32u]);
  float value2 = fp16_to_float(input[input_base + lane + 64u]);
  float value3 = fp16_to_float(input[input_base + lane + 96u]);

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

  const uint32_t rows_in_tile = tiled_row_count(row, arg->m_pad);
  const uint64_t group_stride =
      static_cast<uint64_t>(rows_in_tile) * HADAMARD_TILE_MXU_KT;
  uint64_t output_offset = tiled_row_base(output_base, row, 128u) + lane;
  output[output_offset] = float_to_fp16(value0 * arg->inv_sqrt_dim);
  output_offset += group_stride;
  output[output_offset] = float_to_fp16(value1 * arg->inv_sqrt_dim);
  output_offset += group_stride;
  output[output_offset] = float_to_fp16(value2 * arg->inv_sqrt_dim);
  output_offset += group_stride;
  output[output_offset] = float_to_fp16(value3 * arg->inv_sqrt_dim);
}
#endif

void kernel_hadamard_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<const data_t *>(arg->input_addr);
  auto matrix = reinterpret_cast<const data_t *>(arg->matrix_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t tid = threadIdx.x;
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
  // Small decode shapes use one persistent 1D grid across all matrices. This
  // avoids paying one workgroup launch per matrix while preserving the 2D
  // decomposition used by larger prefill shapes.
  if (arg->base_k == 1u && arg->dim == 128u
      && blockDim.x == 32u
      && arg->input_layout == HADAMARD_INPUT_ROW_MAJOR
      && arg->padded_row_launch == 0u
      && arg->matrix_count > 1u
      && gridDim.y == 1u) {
    const uint32_t row = blockIdx.x % arg->rows;
    const uint32_t first_matrix_idx = blockIdx.x / arg->rows;
    const uint32_t matrix_stride = gridDim.x / arg->rows;
    for (uint32_t matrix_idx = first_matrix_idx;
         matrix_idx < arg->matrix_count; matrix_idx += matrix_stride) {
      const uint64_t output_base =
          static_cast<uint64_t>(matrix_idx) * arg->m_pad * arg->dim;
      kernel_hadamard_r3_shuffle_incremental(
          input, output, arg, matrix_idx, row, output_base);
    }
    return;
  }

  const uint32_t matrix_idx = blockIdx.y;
  const uint32_t row = blockIdx.x;
#else
  const uint32_t physical_row = blockIdx.x;
  const uint32_t launch_rows =
      arg->padded_row_launch != 0 ? arg->m_pad : arg->rows;
  const uint32_t matrix_idx = physical_row / launch_rows;
  const uint32_t row = physical_row - matrix_idx * launch_rows;
#endif
  const bool zero_padding = arg->base_k == 0;
  const uint32_t scratch_dim = zero_padding ? arg->width : arg->dim;
  const uint32_t butterfly_width = arg->width;
  if (matrix_idx >= arg->matrix_count)
    return;

  const uint64_t output_base =
      (uint64_t)matrix_idx * arg->m_pad * arg->dim;
  if (row >= arg->rows) {
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
    const uint32_t rows_in_tile = tiled_row_count(row, arg->m_pad);
    const uint64_t group_stride =
        static_cast<uint64_t>(rows_in_tile) * HADAMARD_TILE_MXU_KT;
    uint64_t offset = tiled_row_base(output_base, row, arg->dim)
                    + tiled_column_offset(tid, group_stride);
    const uint64_t offset_step =
        static_cast<uint64_t>(blockDim.x >> 5) * group_stride;
    for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
      output[offset] = 0;
      offset += offset_step;
    }
#else
    for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
      const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      output[offset] = 0;
    }
#endif
    return;
  }

#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
  if (arg->base_k == 1u && arg->dim == 128u
      && blockDim.x == 32u
      && arg->input_layout == HADAMARD_INPUT_ROW_MAJOR) {
    if (arg->padded_row_launch == 0u) {
      for (uint32_t persistent_row = row; persistent_row < arg->rows;
           persistent_row += gridDim.x) {
        kernel_hadamard_r3_shuffle_incremental(
            input, output, arg, matrix_idx, persistent_row, output_base);
      }
    } else {
      kernel_hadamard_r3_shuffle_incremental(
          input, output, arg, matrix_idx, row, output_base);
    }
    return;
  }
#endif

  auto scratch = reinterpret_cast<float *>(
      __local_mem(scratch_dim * sizeof(float)));
  const uint64_t input_matrix_base =
      (uint64_t)matrix_idx
      * (arg->input_layout == HADAMARD_INPUT_GEMM_A_TILED
             ? arg->m_pad : arg->rows)
      * arg->dim;
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
  const uint32_t rows_in_tile = tiled_row_count(row, arg->m_pad);
  const uint64_t group_stride =
      static_cast<uint64_t>(rows_in_tile) * HADAMARD_TILE_MXU_KT;
  uint64_t input_offset = input_matrix_base
                        + tiled_row_base(0, row, arg->dim)
                        + tiled_column_offset(tid, group_stride);
  const uint64_t input_offset_step =
      static_cast<uint64_t>(blockDim.x >> 5) * group_stride;
#endif
  for (uint32_t column = tid; column < scratch_dim; column += blockDim.x) {
    if (column >= arg->dim) {
      scratch[column] = 0.0f;
    } else if (arg->input_layout == HADAMARD_INPUT_GEMM_A_TILED) {
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      scratch[column] = fp16_to_float(input[input_offset]);
#else
      const uint64_t offset = input_matrix_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      scratch[column] = fp16_to_float(input[offset]);
#endif
    } else {
      scratch[column] =
          fp16_to_float(input[input_matrix_base + (uint64_t)row * arg->dim
                              + column]);
    }
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
    input_offset += input_offset_step;
#endif
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
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
    uint64_t offset = tiled_row_base(output_base, row, arg->dim)
                    + tiled_column_offset(tid, group_stride);
    const uint64_t offset_step =
        static_cast<uint64_t>(blockDim.x >> 5) * group_stride;
#endif
    for (uint32_t column = tid; column < arg->dim; column += blockDim.x) {
      const float transformed = scratch[column] * arg->inv_sqrt_dim;
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      output[offset] = float_to_fp16(transformed);
      offset += offset_step;
#else
      const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt);
      output[offset] = float_to_fp16(transformed);
#endif
    }
    return;
  }

  // Keep a thread on one butterfly column while producing four base-transform
  // outputs. Each intermediate scratch value is then loaded once and reused
  // by four accumulators instead of being loaded once per out_k.
  for (uint32_t width_col = tid; width_col < arg->width;
       width_col += blockDim.x) {
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
    const bool incremental_output = (arg->width & 31u) == 0u;
    uint64_t output_offset = tiled_row_base(output_base, row, arg->dim)
                           + tiled_column_offset(width_col, group_stride);
    const uint64_t output_k_stride =
        static_cast<uint64_t>(arg->width >> 5) * group_stride;
#endif
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
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      if (incremental_output) {
        output[output_offset] = float_to_fp16(sum0);
        output[output_offset + output_k_stride] = float_to_fp16(sum1);
        output[output_offset + 2u * output_k_stride] = float_to_fp16(sum2);
        output[output_offset + 3u * output_k_stride] = float_to_fp16(sum3);
        output_offset += 4u * output_k_stride;
      } else {
#endif
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
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      }
#endif
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
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      if (incremental_output) {
        output[output_offset] = float_to_fp16(sum);
        output_offset += output_k_stride;
      } else {
#endif
        output[output_base + gemm_a_tiled_elem_offset(
          row, column, arg->m_pad, arg->dim,
          arg->log2_mt, arg->log2_mxu_kt)] = float_to_fp16(sum);
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
      }
#endif
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
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 3
  constexpr uint32_t kGridDimensions = 2;
#else
  constexpr uint32_t kGridDimensions = 1;
#endif
  return vx_spawn_threads(
      kGridDimensions, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
