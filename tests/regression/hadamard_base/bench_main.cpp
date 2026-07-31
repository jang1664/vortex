#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

#include <vortex.h>

#include "bench_util.h"
#include "common.h"
#include "../vector_common/fp16.h"

using data_t = fp16_t;

#ifndef HADAMARD_BASE_VARIANT_TAG
#define HADAMARD_BASE_VARIANT_TAG 0
#endif

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

#define RT_CHECK(expr)                                                   \
  do {                                                                   \
    const int ret = (expr);                                              \
    if (ret != 0) {                                                      \
      std::fprintf(stderr, "Error: %s returned %d\n", #expr, ret);      \
      cleanup();                                                         \
      return -1;                                                         \
    }                                                                    \
  } while (0)

static void initialize_values(std::vector<data_t>& values) {
  for (size_t index = 0; index < values.size(); ++index) {
    const int value =
        static_cast<int>((index * 1103515245u + 12345u) & 0xffu) - 128;
    values[index] = float_to_fp16(static_cast<float>(value) / 64.0f);
  }
}

int main(int argc, char** argv) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench))
    return -1;

  uint32_t rows = 1;
  uint32_t base_k = 172;
  uint32_t width = 64;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "-rows") == 0 && index + 1 < argc)
      rows = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-base-k") == 0 && index + 1 < argc)
      base_k = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-width") == 0 && index + 1 < argc)
      width = static_cast<uint32_t>(std::strtoul(argv[++index], nullptr, 10));
    else if (std::strcmp(argv[index], "-h") == 0
             || std::strcmp(argv[index], "--help") == 0) {
      std::printf(
          "Usage: %s [--warmup=N] [--iterations=N] [--csv] "
          "[--output=PATH] [--output-append] "
          "[--power-measure-latency[=on|off]] "
          "[-rows N] [-base-k K] [-width W]\n",
          argv[0]);
      return 0;
    }
  }

  const uint64_t total =
      static_cast<uint64_t>(rows) * base_k * width;
  if (rows == 0 || base_k == 0 || width == 0
      || total > std::numeric_limits<uint32_t>::max()) {
    std::fprintf(stderr,
                 "Invalid Hadamard base shape: rows=%u base_k=%u width=%u\n",
                 rows, base_k, width);
    return -1;
  }

  std::vector<data_t> input, matrix;
  if (bench.copy_inputs) {
    input.resize(total);
    matrix.resize(static_cast<size_t>(base_k) * base_k);
    initialize_values(input);
    initialize_values(matrix);
  }

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart())
    return -1;

  RT_CHECK(vx_dev_open(&device));
  uint64_t warps = 0;
  uint64_t threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &threads));
  const uint32_t block_dim =
      std::min<uint32_t>(256, static_cast<uint32_t>(warps * threads));
#if HADAMARD_BASE_VARIANT_TAG == 1
  const uint64_t work_items = static_cast<uint64_t>(rows) * width;
#else
  const uint64_t work_items = total;
#endif
  const uint32_t grid_dim = static_cast<uint32_t>(
      (work_items + block_dim - 1) / block_dim);

  const uint64_t tensor_bytes = total * sizeof(data_t);
  const uint64_t matrix_bytes =
      static_cast<uint64_t>(base_k) * base_k * sizeof(data_t);
  RT_CHECK(vx_mem_alloc(device, tensor_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, matrix_bytes, VX_MEM_READ, &matrix_buffer));
  RT_CHECK(vx_mem_alloc(device, tensor_bytes, VX_MEM_WRITE, &output_buffer));
  if (bench.copy_inputs) {
    RT_CHECK(vx_copy_to_dev(input_buffer, input.data(), 0, tensor_bytes));
    RT_CHECK(vx_copy_to_dev(matrix_buffer, matrix.data(), 0, matrix_bytes));
  }

  kernel_arg_t kernel_arg{};
  kernel_arg.kernel_id = KERNEL_HADAMARD_BASE;
  kernel_arg.grid_dim[0] = grid_dim;
  kernel_arg.grid_dim[1] = kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = block_dim;
  kernel_arg.block_dim[1] = kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(matrix_buffer, &kernel_arg.matrix_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.rows = rows;
  kernel_arg.base_k = base_k;
  kernel_arg.width = width;
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(
      device, &kernel_arg, sizeof(kernel_arg), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(
      device, "kernel.vxbin", &kernel_buffer));

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
    if (index == 0)
      first_latency_us = elapsed_us;
    stats.record(elapsed_us);
    const auto iteration_perf =
        vx_bench::dump_iteration_perf(device, bench, index);
    if (index == 0)
      first_iter_perf = iteration_perf;
  }

  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }
  stats.report("hadamard_base", bench);
  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          "hadamard_base")) {
    cleanup();
    return -1;
  }
  if (!vx_bench::run_power_measurement(
          "hadamard_base", bench, device, kernel_buffer, args_buffer,
          bench.power_measure_latency)) {
    cleanup();
    return -1;
  }

  cleanup();
  return 0;
}
