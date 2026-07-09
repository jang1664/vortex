// Benchmark harness for vecadd. Functional validation stays in main.cpp; this
// binary measures repeated kernel launch latency with fixed inputs.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <type_traits>
#include <vector>

#include <vortex.h>

#include "bench_util.h"
#include "common.h"

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
static uint32_t size = 8192;
static uint32_t seed = 50;

static vx_device_h device = nullptr;
static vx_buffer_h src0_buffer = nullptr;
static vx_buffer_h src1_buffer = nullptr;
static vx_buffer_h dst_buffer = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;

static void cleanup() {
  if (src0_buffer) vx_mem_free(src0_buffer);
  if (src1_buffer) vx_mem_free(src1_buffer);
  if (dst_buffer) vx_mem_free(dst_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

template <typename T>
static T generate_value() {
  if constexpr (std::is_integral<T>::value) {
    return static_cast<T>((rand() % 65536) - 32768);
  } else {
    return static_cast<T>(static_cast<float>(rand()) / RAND_MAX);
  }
}

static void print_usage(const char* prog) {
  printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
         "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-n SIZE] [-seed S] [-k kernel.vxbin]\n",
         prog);
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
      size = static_cast<uint32_t>(atoi(argv[++i]));
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

  if (size == 0) {
    fprintf(stderr, "Invalid size: %u\n", size);
    return -1;
  }

  const uint32_t num_points = size;
  const uint64_t buffer_bytes = static_cast<uint64_t>(num_points) * sizeof(TYPE);

  if (!bench.csv) {
    printf("Vecadd Bench: size=%u bytes=%lu warmup=%d iterations=%d\n",
           num_points, buffer_bytes, bench.warmup, bench.iterations);
  }

  std::vector<TYPE> h_src0(num_points);
  std::vector<TYPE> h_src1(num_points);
  srand(seed);
  for (uint32_t i = 0; i < num_points; ++i) {
    h_src0[i] = generate_value<TYPE>();
    h_src1[i] = generate_value<TYPE>();
  }

  RT_CHECK(vx_dev_open(&device));

  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &src0_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &src1_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_WRITE, &dst_buffer));

  kernel_arg_t kernel_arg = {};
  kernel_arg.num_points = num_points;
  RT_CHECK(vx_mem_address(src0_buffer, &kernel_arg.src0_addr));
  RT_CHECK(vx_mem_address(src1_buffer, &kernel_arg.src1_addr));
  RT_CHECK(vx_mem_address(dst_buffer, &kernel_arg.dst_addr));

  RT_CHECK(vx_copy_to_dev(src0_buffer, h_src0.data(), 0, buffer_bytes));
  RT_CHECK(vx_copy_to_dev(src1_buffer, h_src1.data(), 0, buffer_bytes));
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i + 1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
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
    printf("iteration %0d/%0d, elapsed:%f\n", i + 1, bench.iterations, stats.last());
    fflush(stdout);
  }

  stats.report("vecadd", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          "vecadd")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "vecadd", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
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
