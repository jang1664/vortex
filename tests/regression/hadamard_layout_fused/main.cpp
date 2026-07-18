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

static uint32_t spinquant_base_k(uint32_t dim) {
  if (dim == 11008)
    return 172;
  return (dim != 0 && (dim & (dim - 1)) == 0) ? 1 : 0;
}

static void reference_hadamard(
    const std::vector<data_t>& input,
    const std::vector<data_t>& matrix,
    std::vector<data_t>& output,
    uint32_t matrix_count,
    uint32_t rows,
    uint32_t dim,
    uint32_t base_k) {
  const uint32_t width = dim / base_k;
  const float scale = 1.0f / std::sqrt(static_cast<float>(dim));
  std::vector<float> scratch(dim);
  for (uint32_t matrix_idx = 0; matrix_idx < matrix_count; ++matrix_idx) {
    for (uint32_t row = 0; row < rows; ++row) {
      const uint64_t base = ((uint64_t)matrix_idx * rows + row) * dim;
      for (uint32_t column = 0; column < dim; ++column)
        scratch[column] = fp16_to_float(input[base + column]);
      for (uint32_t stride = 1; stride < width; stride <<= 1) {
        for (uint32_t block = 0; block < dim; block += stride << 1) {
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
        if (base_k == 1) {
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
                     uint32_t base_k) {
  std::printf("%s: matrices=%u rows=%u m_pad=%u dim=%u base=%u\n",
              name, matrix_count, rows, m_pad, dim, base_k);
  const uint32_t input_elems = matrix_count * rows * dim;
  const uint32_t output_elems = matrix_count * m_pad * dim;
  std::vector<data_t> input(input_elems);
  std::vector<data_t> matrix(base_k * base_k);
  std::vector<data_t> reference_row(input_elems);
  std::vector<data_t> reference_tiled(output_elems, 0);
  std::vector<data_t> actual(output_elems);
  for (uint32_t index = 0; index < input_elems; ++index)
    input[index] = float_to_fp16((int(index % 29) - 14) / 16.0f);
  for (uint32_t row = 0; row < base_k; ++row) {
    for (uint32_t column = 0; column < base_k; ++column) {
      const float value = row == column ? 1.0f
          : (((row + column) & 1u) ? -0.25f : 0.25f);
      matrix[row * base_k + column] = float_to_fp16(value);
    }
  }
  reference_hadamard(input, matrix, reference_row,
                     matrix_count, rows, dim, base_k);
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
  uint32_t max_localmem = 0;
  RT_CHECK(vx_check_occupancy(
      device, static_cast<uint32_t>(threads), &max_localmem));
  if ((uint64_t)dim * sizeof(float) > max_localmem) {
    std::fprintf(stderr,
                 "Hadamard scratch exceeds local memory: required=%lu available=%u\n",
                 (uint64_t)dim * sizeof(float), max_localmem);
    return false;
  }

  ScopedBuffers buffers;
  const uint64_t input_bytes = (uint64_t)input_elems * sizeof(data_t);
  const uint64_t matrix_bytes = (uint64_t)matrix.size() * sizeof(data_t);
  const uint64_t output_bytes = (uint64_t)output_elems * sizeof(data_t);
  RT_CHECK(vx_mem_alloc_aligned(
      device, input_bytes, 512, VX_MEM_READ, &buffers.input));
  RT_CHECK(vx_mem_alloc_aligned(
      device, matrix_bytes, 512, VX_MEM_READ, &buffers.matrix));
  RT_CHECK(vx_mem_alloc_aligned(
      device, output_bytes, 512, VX_MEM_WRITE, &buffers.output));
  RT_CHECK(vx_copy_to_dev(buffers.input, input.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(buffers.matrix, matrix.data(), 0, matrix_bytes));
  kernel_arg_t arg{};
  arg.kernel_id = KERNEL_HADAMARD_LAYOUT_FUSED;
  arg.grid_dim[0] = matrix_count * m_pad;
  arg.grid_dim[1] = arg.grid_dim[2] = 1;
  // The fused FWHT scratch is synchronized within one hardware warp.
  arg.block_dim[0] = static_cast<uint32_t>(threads);
  arg.block_dim[1] = arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(buffers.input, &arg.input_addr));
  RT_CHECK(vx_mem_address(buffers.matrix, &arg.matrix_addr));
  RT_CHECK(vx_mem_address(buffers.output, &arg.output_addr));
  arg.matrix_count = matrix_count;
  arg.rows = rows;
  arg.m_pad = m_pad;
  arg.dim = dim;
  arg.base_k = base_k;
  arg.width = dim / base_k;
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
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--kernel") == 0 && index + 1 < argc)
      kernel_file = argv[++index];
    else if (std::strcmp(argv[index], "-m") == 0 && index + 1 < argc)
      rows = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-n") == 0 && index + 1 < argc)
      matrix_count = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-k") == 0 && index + 1 < argc)
      dim = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else {
      std::fprintf(stderr,
                   "Usage: %s [--kernel kernel.vxbin] [-m N] [-n N] [-k N]\n",
                   argv[0]);
      return 2;
    }
  }
  const uint32_t base_k = spinquant_base_k(dim);
  if (rows == 0 || rows > HADAMARD_TILE_DMA_MT || matrix_count == 0
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
  const bool passed =
      run_case("requested", matrix_count, rows, (rows + 7) & ~7u, dim, base_k)
      && run_case("r4_mixed_radix", 1, 2, 8, 96, 3)
      && run_case("r4_llama2_7b", 1, 1, 8, 11008, 172);
  cleanup();
  return passed ? 0 : 1;
}
