#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <vortex.h>

using data_t = fp16_t;

static vx_device_h device = nullptr;
static vx_buffer_h kernel_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static vx_buffer_h input_buffer = nullptr;
static vx_buffer_h matrix_buffer = nullptr;
static vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (matrix_buffer) vx_mem_free(matrix_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (kernel_buffer) vx_mem_free(kernel_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

#define RT_CHECK(_expr)                                                    \
  do {                                                                     \
    const int _ret = (_expr);                                              \
    if (_ret == 0)                                                         \
      break;                                                               \
    std::fprintf(stderr, "Error: '%s' returned %d\n", #_expr, _ret);     \
    cleanup();                                                             \
    return -1;                                                             \
  } while (false)

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

static void initialize_values(std::vector<data_t>& values, float scale) {
  for (size_t index = 0; index < values.size(); ++index) {
    const int value = static_cast<int>((index * 1103515245u + 12345u) & 0xffu) - 128;
    values[index] = float_to_fp16(scale * static_cast<float>(value) / 64.0f);
  }
}

int main(int argc, char** argv) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench))
    return -1;

  uint32_t rows = 2;
  uint32_t matrix_count = 32;
  uint32_t dim = 128;
  bool factorized = true;
  uint32_t input_layout = HADAMARD_INPUT_ROW_MAJOR;
  bool padded_row_launch = false;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "-m") == 0 && index + 1 < argc)
      rows = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-n") == 0 && index + 1 < argc)
      matrix_count = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-k") == 0 && index + 1 < argc)
      dim = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "--hadamard-variant") == 0
             && index + 1 < argc) {
      const char* value = argv[++index];
      if (std::strcmp(value, "zero_padding") == 0)
        factorized = false;
      else if (std::strcmp(value, "factorized") == 0)
        factorized = true;
      else {
        std::fprintf(stderr, "Unsupported Hadamard variant: %s\n", value);
        return -1;
      }
    }
    else if (std::strcmp(argv[index], "--layout-from") == 0
             && index + 1 < argc) {
      const char* value = argv[++index];
      if (std::strcmp(value, "row_major_fp16") == 0
          || std::strcmp(value, "head_major_row_fp16") == 0)
        input_layout = HADAMARD_INPUT_ROW_MAJOR;
      else if (std::strcmp(value, "gemm_a_tiled") == 0)
        input_layout = HADAMARD_INPUT_GEMM_A_TILED;
      else {
        std::fprintf(stderr, "Unsupported input layout: %s\n", value);
        return -1;
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
        return -1;
      }
    }
    else if (std::strcmp(argv[index], "-h") == 0 ||
             std::strcmp(argv[index], "--help") == 0) {
      std::printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
                  "[--output=PATH] [--output-append] "
                  "[--power-measure-latency[=on|off]] [-m rows] [-n matrices] [-k dim] "
                  "[--hadamard-variant zero_padding|factorized] "
                  "[--layout-from row_major_fp16|head_major_row_fp16|gemm_a_tiled] "
                  "[--launch-rows real|padded]\n",
                  argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "Unknown argument: %s\n", argv[index]);
      return -1;
    }
  }

  const uint32_t base_k = spinquant_base_k(dim);
  if (rows == 0 || matrix_count == 0 || base_k == 0 ||
      dim % HADAMARD_TILE_MXU_KT != 0) {
    std::fprintf(stderr, "Unsupported shape: m=%u n=%u k=%u\n",
                 rows, matrix_count, dim);
    return -1;
  }

  const uint32_t m_pad = (rows + 7u) & ~7u;
  const uint32_t scratch_dim = factorized ? dim : next_power_of_two(dim);
  const uint64_t logical_input_elems =
      static_cast<uint64_t>(matrix_count) * rows * dim;
  const uint64_t output_elems = static_cast<uint64_t>(matrix_count) * m_pad * dim;
  const uint64_t input_elems =
      input_layout == HADAMARD_INPUT_GEMM_A_TILED
          ? output_elems : logical_input_elems;
  const uint64_t input_bytes = input_elems * sizeof(data_t);
  const uint64_t matrix_bytes = static_cast<uint64_t>(base_k) * base_k * sizeof(data_t);
  const uint64_t output_bytes = output_elems * sizeof(data_t);

  std::vector<data_t> logical_input(logical_input_elems);
  std::vector<data_t> input(input_elems, 0);
  std::vector<data_t> matrix(static_cast<size_t>(base_k) * base_k);
  initialize_values(logical_input, 1.0f);
  if (input_layout == HADAMARD_INPUT_GEMM_A_TILED) {
    for (uint32_t matrix_idx = 0; matrix_idx < matrix_count; ++matrix_idx) {
      const uint64_t logical_base =
          (uint64_t)matrix_idx * rows * dim;
      const uint64_t tiled_base =
          (uint64_t)matrix_idx * m_pad * dim;
      for (uint32_t row = 0; row < rows; ++row) {
        for (uint32_t column = 0; column < dim; ++column) {
          const uint64_t offset = tiled_base + gemm_a_tiled_elem_offset(
              row, column, m_pad, dim,
              log2_u32(HADAMARD_TILE_DMA_MT),
              log2_u32(HADAMARD_TILE_MXU_KT));
          input[offset] = logical_input[
              logical_base + (uint64_t)row * dim + column];
        }
      }
    }
  } else {
    input = logical_input;
  }
  for (uint32_t row = 0; row < base_k; ++row) {
    for (uint32_t column = 0; column < base_k; ++column) {
      const float value = row == column ? 1.0f
          : (((row + column) & 1u) ? -0.25f : 0.25f);
      matrix[row * base_k + column] = float_to_fp16(value);
    }
  }

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart())
    return -1;

  RT_CHECK(vx_dev_open(&device));
  uint64_t num_threads = 0;
  uint64_t num_warps = 1;
  uint32_t max_local_mem = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG >= 1
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
#endif
#if HADAMARD_LAYOUT_FUSED_VARIANT_TAG == 2
  const uint32_t launched_rows = padded_row_launch ? m_pad : rows;
  const uint32_t factor_width = factorized ? dim / base_k : scratch_dim;
  const bool use_multiwarp =
      static_cast<uint64_t>(matrix_count) * launched_rows < num_warps
      && (!factorized || factor_width > num_threads);
  const uint32_t launch_threads = static_cast<uint32_t>(
      num_threads * (use_multiwarp ? num_warps : 1u));
#else
  const uint32_t launch_threads =
      static_cast<uint32_t>(num_threads * num_warps);
#endif
  RT_CHECK(vx_check_occupancy(device, launch_threads,
                              &max_local_mem));
  if (static_cast<uint64_t>(scratch_dim) * sizeof(float) > max_local_mem) {
    std::fprintf(stderr, "Hadamard scratch does not fit in local memory\n");
    cleanup();
    return -1;
  }

  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, input_bytes, 512, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, matrix_bytes, 512, VX_MEM_READ, &matrix_buffer));
  RT_CHECK(vx_mem_alloc_aligned(device, output_bytes, 512, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, input.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(matrix_buffer, matrix.data(), 0, matrix_bytes));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_HADAMARD_LAYOUT_FUSED;
  arg.grid_dim[0] =
      matrix_count * (padded_row_launch ? m_pad : rows);
  arg.block_dim[0] = launch_threads;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(matrix_buffer, &arg.matrix_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.matrix_count = matrix_count;
  arg.rows = rows;
  arg.m_pad = m_pad;
  arg.dim = dim;
  arg.base_k = factorized ? base_k : 0;
  arg.width = factorized ? dim / base_k : scratch_dim;
  arg.input_layout = input_layout;
  arg.padded_row_launch = padded_row_launch ? 1u : 0u;
  arg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));
  arg.log2_mt = log2_u32(HADAMARD_TILE_DMA_MT);
  arg.log2_mxu_kt = log2_u32(HADAMARD_TILE_MXU_KT);
  arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  for (int index = 0; index < bench.warmup; ++index) {
    RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  if (!latency_power.begin_latency_window()) {
    cleanup();
    return -1;
  }
  for (int index = 0; index < bench.iterations; ++index) {
    vx_bench::Stopwatch stopwatch;
    stopwatch.start();
    RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    const double elapsed_us = stopwatch.stop_us();
    if (index == 0) first_latency_us = elapsed_us;
    stats.record(elapsed_us);
    const auto iter_perf = vx_bench::dump_iteration_perf(device, bench, index);
    if (index == 0) first_iter_perf = iter_perf;
  }

  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }
  stats.report("hadamard_layout_fused", bench);
  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "hadamard_layout_fused")) {
    cleanup();
    return -1;
  }
  if (!vx_bench::run_power_measurement(
          "hadamard_layout_fused", bench, device, kernel_buffer, args_buffer,
          bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
