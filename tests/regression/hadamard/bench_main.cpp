#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

#include <vortex.h>

#include "bench_util.h"
#include "common.h"
#include "../vector_common/fp16.h"

using data_t = fp16_t;

#define RT_CHECK(_expr)                                         \
  do {                                                          \
    int _ret = _expr;                                           \
    if (0 == _ret)                                              \
      break;                                                    \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);    \
    cleanup();                                                  \
    exit(-1);                                                   \
  } while (false)

static const char* kernel_file = "kernel.vxbin";

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static vx_buffer_h input_buffer = nullptr;
static vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static uint32_t next_power_of_two(uint32_t value) {
  if (value <= 1) {
    return 1;
  }

  --value;
  value |= value >> 1;
  value |= value >> 2;
  value |= value >> 4;
  value |= value >> 8;
  value |= value >> 16;
  return value + 1;
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& value : vec) {
    const float x = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;
    value = float_to_fp16(x);
  }
}

static void print_usage(const char* prog) {
  printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
         "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
         "[-rows N] [-dim D] [-seed S] [-k kernel.vxbin]\n",
         prog);
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  uint32_t rows = 4;
  uint32_t dim = 11008;
  uint32_t seed = 42;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-rows") == 0 && i + 1 < argc) {
      rows = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-dim") == 0 && i + 1 < argc) {
      dim = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-seed") == 0 && i + 1 < argc) {
      seed = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-k") == 0 && i + 1 < argc) {
      kernel_file = argv[++i];
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      print_usage(argv[0]);
      return 0;
    } else {
      print_usage(argv[0]);
      return -1;
    }
  }

  if (rows == 0 || dim == 0 || dim > (1u << 30)) {
    fprintf(stderr, "Invalid shape: rows=%u dim=%u\n", rows, dim);
    return -1;
  }

  const uint32_t padded_dim = next_power_of_two(dim);
  const uint64_t numel64 = static_cast<uint64_t>(rows) * dim;
  if (numel64 > std::numeric_limits<uint32_t>::max()) {
    fprintf(stderr, "Input is too large: rows=%u dim=%u\n", rows, dim);
    return -1;
  }
  const uint32_t numel = static_cast<uint32_t>(numel64);
  const uint64_t buffer_bytes = static_cast<uint64_t>(numel) * sizeof(data_t);

  if (!bench.csv) {
    printf("Hadamard Bench: rows=%u dim=%u padded_dim=%u warmup=%d iterations=%d\n",
           rows, dim, padded_dim, bench.warmup, bench.iterations);
  }

  std::vector<data_t> h_input(numel);
  srand(seed);
  initialize_random(h_input);

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_warps, num_threads, local_mem_size;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));

  const uint32_t threads_per_block = std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
  uint32_t max_localmem = 0;
  RT_CHECK(vx_check_occupancy(device, threads_per_block, &max_localmem));
  const uint32_t scratch_bytes = padded_dim * sizeof(float);
  if (scratch_bytes > max_localmem) {
    fprintf(stderr,
            "Hadamard scratch does not fit local memory: padded_dim=%u scratch=%u max_per_group=%u total_lmem=%lu\n",
            padded_dim, scratch_bytes, max_localmem, local_mem_size);
    cleanup();
    return -1;
  }

  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_HADAMARD;
  kernel_arg.grid_dim[0] = rows;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.rows = rows;
  kernel_arg.dim = dim;
  kernel_arg.padded_dim = padded_dim;
  kernel_arg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  if (!latency_power.begin_latency_window()) {
    cleanup();
    return -1;
  }
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    const double elapsed_us = sw.stop_us();
    if (i == 0)
      first_latency_us = elapsed_us;
    stats.record(elapsed_us);
    const vx_bench::IterationPerf iter_perf =
        vx_bench::dump_iteration_perf(device, bench, i);
    if (i == 0)
      first_iter_perf = iter_perf;
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }

  stats.report("hadamard", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          "hadamard")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "hadamard", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
