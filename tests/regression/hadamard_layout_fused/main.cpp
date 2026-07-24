#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <vortex.h>

using data_t = fp16_t;

static vx_device_h device = nullptr;
static vx_buffer_h kernel_buffer = nullptr;

static void cleanup() {
  if (kernel_buffer) {
    vx_mem_free(kernel_buffer);
    kernel_buffer = nullptr;
  }
  if (device) {
    vx_dev_close(device);
    device = nullptr;
  }
}

#define RT_CHECK(expr)                                                   \
  do {                                                                   \
    const int ret = (expr);                                              \
    if (ret != 0) {                                                      \
      std::fprintf(stderr, "Error: %s returned %d\n", #expr, ret);      \
      return false;                                                      \
    }                                                                    \
  } while (0)

struct ScopedBuffers {
  vx_buffer_h args = nullptr;
  vx_buffer_h input = nullptr;
  vx_buffer_h matrix = nullptr;
  vx_buffer_h output = nullptr;

  ~ScopedBuffers() {
    if (args) vx_mem_free(args);
    if (input) vx_mem_free(input);
    if (matrix) vx_mem_free(matrix);
    if (output) vx_mem_free(output);
  }
};

static uint32_t log2_u32(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) < value) ++result;
  return result;
}

static bool is_power_of_two(uint32_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

static uint32_t next_power_of_two(uint32_t value) {
  if (value <= 1)
    return 1;
  --value;
  value |= value >> 1;
  value |= value >> 2;
  value |= value >> 4;
  value |= value >> 8;
  value |= value >> 16;
  return value + 1;
}

static uint32_t spinquant_base_k(uint32_t dim) {
  if (dim % 172 == 0 && is_power_of_two(dim / 172))
    return 172;
  if (dim % 28 == 0 && is_power_of_two(dim / 28))
    return 28;
  return is_power_of_two(dim) ? 1 : 0;
}

static void reference_hadamard(
    const std::vector<data_t>& input,
    const std::vector<data_t>& matrix,
    std::vector<data_t>& output,
    uint32_t matrix_count,
    uint32_t rows,
    uint32_t dim,
    uint32_t base_k,
    bool factorized) {
  const uint32_t width =
      factorized ? dim / base_k : next_power_of_two(dim);
  const uint32_t scratch_dim = factorized ? dim : width;
  const float scale = 1.0f / std::sqrt(static_cast<float>(dim));
  std::vector<float> scratch(scratch_dim);
  for (uint32_t matrix_idx = 0; matrix_idx < matrix_count; ++matrix_idx) {
    for (uint32_t row = 0; row < rows; ++row) {
      const uint64_t base = ((uint64_t)matrix_idx * rows + row) * dim;
      for (uint32_t column = 0; column < scratch_dim; ++column) {
        scratch[column] = column < dim
            ? fp16_to_float(input[base + column])
            : 0.0f;
      }
      for (uint32_t stride = 1; stride < width; stride <<= 1) {
        for (uint32_t block = 0; block < scratch_dim; block += stride << 1) {
          for (uint32_t lane = 0; lane < stride; ++lane) {
            const float a = scratch[block + lane];
            const float b = scratch[block + lane + stride];
            scratch[block + lane] = a + b;
            scratch[block + lane + stride] = a - b;
          }
        }
      }
      for (uint32_t column = 0; column < dim; ++column) {
        float value;
        if (!factorized || base_k == 1) {
          value = scratch[column] * scale;
        } else {
          const uint32_t out_k = column / width;
          const uint32_t width_col = column % width;
          value = 0.0f;
          for (uint32_t in_k = 0; in_k < base_k; ++in_k) {
            const float intermediate = fp16_to_float(float_to_fp16(
                scratch[in_k * width + width_col] * scale));
            value += fp16_to_float(matrix[out_k * base_k + in_k])
                   * intermediate;
          }
        }
        output[base + column] = float_to_fp16(value);
      }
    }
  }
}

static bool run_case(const char* name,
                     uint32_t matrix_count,
                     uint32_t rows,
                     uint32_t m_pad,
                     uint32_t dim,
                     uint32_t base_k,
                     bool factorized = true,
                     bool tiled_input = false,
                     bool padded_row_launch = false) {
  std::printf("%s: matrices=%u rows=%u m_pad=%u dim=%u base=%u variant=%s input=%s launch=%s\n",
              name, matrix_count, rows, m_pad, dim, base_k,
              factorized ? "factorized" : "zero_padding",
              tiled_input ? "gemm_a_tiled" : "row_major",
              padded_row_launch ? "padded" : "real");
  const uint32_t input_elems = matrix_count * rows * dim;
  const uint32_t output_elems = matrix_count * m_pad * dim;
  std::vector<data_t> input(input_elems);
  std::vector<data_t> device_input(
      tiled_input ? output_elems : input_elems, 0);
  std::vector<data_t> matrix(base_k * base_k);
  std::vector<data_t> reference_row(input_elems);
  std::vector<data_t> reference_tiled(output_elems, 0);
  std::vector<data_t> actual(output_elems);
  std::vector<data_t> zero_output(output_elems, 0);
  for (uint32_t index = 0; index < input_elems; ++index)
    input[index] = float_to_fp16((int(index % 29) - 14) / 16.0f);
  if (tiled_input) {
    for (uint32_t matrix_idx = 0; matrix_idx < matrix_count; ++matrix_idx) {
      const uint64_t input_base = (uint64_t)matrix_idx * rows * dim;
      const uint64_t tiled_base = (uint64_t)matrix_idx * m_pad * dim;
      for (uint32_t row = 0; row < rows; ++row) {
        for (uint32_t column = 0; column < dim; ++column) {
          const uint64_t offset = tiled_base + gemm_a_tiled_elem_offset(
              row, column, m_pad, dim,
              log2_u32(HADAMARD_TILE_DMA_MT),
              log2_u32(HADAMARD_TILE_MXU_KT));
          device_input[offset] =
              input[input_base + (uint64_t)row * dim + column];
        }
      }
    }
  } else {
    device_input = input;
  }
  for (uint32_t row = 0; row < base_k; ++row) {
    for (uint32_t column = 0; column < base_k; ++column) {
      const float value = row == column ? 1.0f
          : (((row + column) & 1u) ? -0.25f : 0.25f);
      matrix[row * base_k + column] = float_to_fp16(value);
    }
  }
  reference_hadamard(input, matrix, reference_row,
                     matrix_count, rows, dim, base_k, factorized);
  for (uint32_t matrix_idx = 0; matrix_idx < matrix_count; ++matrix_idx) {
    const uint64_t output_base = (uint64_t)matrix_idx * m_pad * dim;
    const uint64_t input_base = (uint64_t)matrix_idx * rows * dim;
    for (uint32_t row = 0; row < rows; ++row) {
      for (uint32_t column = 0; column < dim; ++column) {
        const uint64_t offset = output_base + gemm_a_tiled_elem_offset(
            row, column, m_pad, dim,
            log2_u32(HADAMARD_TILE_DMA_MT),
            log2_u32(HADAMARD_TILE_MXU_KT));
        reference_tiled[offset] = reference_row[input_base + row * dim + column];
      }
    }
  }

  uint64_t threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &threads));
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG >= 1
  uint64_t warps = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &warps));
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 2
  const uint32_t launched_rows = padded_row_launch ? m_pad : rows;
  const uint32_t factor_width =
      factorized ? dim / base_k : next_power_of_two(dim);
  const bool use_multiwarp =
      static_cast<uint64_t>(matrix_count) * launched_rows < warps
      && (!factorized || factor_width > threads);
  const uint32_t launch_threads = static_cast<uint32_t>(
      threads * (use_multiwarp ? warps : 1u));
#else
  const uint32_t launch_threads =
      static_cast<uint32_t>(threads * warps);
#endif
#else
  const uint32_t launch_threads = static_cast<uint32_t>(threads);
#endif
  uint32_t max_localmem = 0;
  RT_CHECK(vx_check_occupancy(
      device, launch_threads, &max_localmem));
  const uint32_t scratch_dim =
      factorized ? dim : next_power_of_two(dim);
  if ((uint64_t)scratch_dim * sizeof(float) > max_localmem) {
    std::fprintf(stderr,
                 "Hadamard scratch exceeds local memory: required=%lu available=%u\n",
                 (uint64_t)scratch_dim * sizeof(float), max_localmem);
    return false;
  }

  ScopedBuffers buffers;
  const uint64_t input_bytes =
      (uint64_t)device_input.size() * sizeof(data_t);
  const uint64_t matrix_bytes = (uint64_t)matrix.size() * sizeof(data_t);
  const uint64_t output_bytes = (uint64_t)output_elems * sizeof(data_t);
  RT_CHECK(vx_mem_alloc_aligned(
      device, input_bytes, 512, VX_MEM_READ, &buffers.input));
  RT_CHECK(vx_mem_alloc_aligned(
      device, matrix_bytes, 512, VX_MEM_READ, &buffers.matrix));
  RT_CHECK(vx_mem_alloc_aligned(
      device, output_bytes, 512, VX_MEM_READ_WRITE, &buffers.output));
  RT_CHECK(vx_copy_to_dev(
      buffers.input, device_input.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(buffers.matrix, matrix.data(), 0, matrix_bytes));
  RT_CHECK(vx_copy_to_dev(
      buffers.output, zero_output.data(), 0, output_bytes));
  kernel_arg_t arg{};
  arg.kernel_id = KERNEL_HADAMARD_LAYOUT_FUSED;
  arg.grid_dim[0] =
      matrix_count * (padded_row_launch ? m_pad : rows);
  arg.grid_dim[1] = arg.grid_dim[2] = 1;
  arg.block_dim[0] = launch_threads;
  arg.block_dim[1] = arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(buffers.input, &arg.input_addr));
  RT_CHECK(vx_mem_address(buffers.matrix, &arg.matrix_addr));
  RT_CHECK(vx_mem_address(buffers.output, &arg.output_addr));
  arg.matrix_count = matrix_count;
  arg.rows = rows;
  arg.m_pad = m_pad;
  arg.dim = dim;
  arg.base_k = factorized ? base_k : 0;
  arg.width = factorized ? dim / base_k : scratch_dim;
  arg.input_layout =
      tiled_input ? HADAMARD_INPUT_GEMM_A_TILED : HADAMARD_INPUT_ROW_MAJOR;
  arg.padded_row_launch = padded_row_launch ? 1u : 0u;
  arg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));
  arg.log2_mt = log2_u32(HADAMARD_TILE_DMA_MT);
  arg.log2_mxu_kt = log2_u32(HADAMARD_TILE_MXU_KT);
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &buffers.args));
  RT_CHECK(vx_start(device, kernel_buffer, buffers.args));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(actual.data(), buffers.output, 0, output_bytes));

  int errors = 0;
  for (uint32_t index = 0; index < output_elems; ++index) {
    if (std::fabs(fp16_to_float(actual[index])
                  - fp16_to_float(reference_tiled[index])) > 0.002f)
      ++errors;
  }
  std::printf("%s: %s (%d errors)\n", name, errors ? "FAIL" : "PASS", errors);
  return errors == 0;
}

int main(int argc, char** argv) {
  const char* kernel_file = "kernel.vxbin";
  uint32_t rows = 2;
  uint32_t matrix_count = 32;
  uint32_t dim = 128;
  bool factorized = true;
  bool tiled_input = false;
  bool padded_row_launch = false;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--kernel") == 0 && index + 1 < argc)
      kernel_file = argv[++index];
    else if (std::strcmp(argv[index], "-m") == 0 && index + 1 < argc)
      rows = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-n") == 0 && index + 1 < argc)
      matrix_count = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-k") == 0 && index + 1 < argc)
      dim = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "--hadamard-variant") == 0
             && index + 1 < argc) {
      const char* value = argv[++index];
      if (std::strcmp(value, "factorized") == 0)
        factorized = true;
      else if (std::strcmp(value, "zero_padding") == 0)
        factorized = false;
      else {
        std::fprintf(stderr, "Unsupported Hadamard variant: %s\n", value);
        return 2;
      }
    }
    else if (std::strcmp(argv[index], "--layout-from") == 0
             && index + 1 < argc) {
      const char* value = argv[++index];
      if (std::strcmp(value, "row_major_fp16") == 0
          || std::strcmp(value, "head_major_row_fp16") == 0)
        tiled_input = false;
      else if (std::strcmp(value, "gemm_a_tiled") == 0)
        tiled_input = true;
      else {
        std::fprintf(stderr, "Unsupported input layout: %s\n", value);
        return 2;
      }
    }
    else if (std::strcmp(argv[index], "--launch-rows") == 0
             && index + 1 < argc) {
      const char* value = argv[++index];
      if (std::strcmp(value, "real") == 0)
        padded_row_launch = false;
      else if (std::strcmp(value, "padded") == 0)
        padded_row_launch = true;
      else {
        std::fprintf(stderr, "Unsupported row launch mode: %s\n", value);
        return 2;
      }
    }
    else {
      std::fprintf(stderr,
                   "Usage: %s [--kernel kernel.vxbin] [-m N] [-n N] [-k N] "
                   "[--hadamard-variant zero_padding|factorized] "
                   "[--layout-from row_major_fp16|head_major_row_fp16|gemm_a_tiled] "
                   "[--launch-rows real|padded]\n",
                   argv[0]);
      return 2;
    }
  }
  const uint32_t base_k = spinquant_base_k(dim);
  if (rows == 0 || matrix_count == 0
      || dim % HADAMARD_TILE_MXU_KT != 0 || base_k == 0) {
    std::fprintf(stderr,
                 "Unsupported requested case: m=%u n=%u k=%u\n",
                 rows, matrix_count, dim);
    return 2;
  }
  if (vx_dev_open(&device) != 0
      || vx_upload_kernel_file(device, kernel_file, &kernel_buffer) != 0) {
    cleanup();
    return 1;
  }
  bool passed = run_case(
      "requested", matrix_count, rows, (rows + 7) & ~7u, dim, base_k,
      factorized, tiled_input, padded_row_launch);
  cleanup();
  return passed ? 0 : 1;
}
