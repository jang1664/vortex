// Benchmark harness for dropout. See softmax/bench_main.cpp for design notes.

#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <cmath>
#include <cstdio>
#include <vortex.h>
#include "common.h"
#include "bench_util.h"

#define FLOAT_ULP 6

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

template <typename T>
struct Compare {};

template <>
struct Compare<int> {
  static int gen() { return rand(); }
  static bool eq(int a, int b) { return a == b; }
};

template <>
struct Compare<float> {
  static float gen() { return static_cast<float>(rand()) / RAND_MAX; }
  static bool eq(float a, float b) {
    union fi_t { float f; int32_t i; };
    fi_t fa, fb; fa.f = a; fb.f = b;
    return std::abs(fa.i - fb.i) <= FLOAT_ULP;
  }
};

const char* kernel_file = "kernel.vxbin";
uint32_t size = 1024;

vx_device_h device = nullptr;
vx_buffer_h src0_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
kernel_arg_t kernel_arg = {};

static void cleanup() {
  if (device) {
    if (src0_buffer) vx_mem_free(src0_buffer);
    if (dst_buffer)  vx_mem_free(dst_buffer);
    if (krnl_buffer) vx_mem_free(krnl_buffer);
    if (args_buffer) vx_mem_free(args_buffer);
    vx_dev_close(device);
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  // Reuse getopt for the original -n / -k flags.
  optind = 1;
  int c;
  while ((c = getopt(argc, argv, "n:k:h")) != -1) {
    switch (c) {
      case 'n': size = atoi(optarg); break;
      case 'k': kernel_file = optarg; break;
      case 'h':
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-n SIZE] [-k FILE]\n",
               argv[0]);
        return 0;
      default:
        printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
               "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-n SIZE] [-k FILE]\n",
               argv[0]);
        return -1;
    }
  }

  if (!bench.csv) {
    printf("Dropout Bench: size=%u  warmup=%d iterations=%d\n",
           size, bench.warmup, bench.iterations);
  }

  RT_CHECK(vx_dev_open(&device));

  std::srand(50);
  uint32_t num_points = size;
  float dropout_p = 0.2f;
  uint32_t buf_size = num_points * sizeof(TYPE);

  kernel_arg.num_points = num_points;
  kernel_arg.dropout_p  = dropout_p;
  kernel_arg.multiplier = 1.0f / (1.0f - dropout_p);

  RT_CHECK(vx_mem_alloc(device, buf_size, VX_MEM_READ,  &src0_buffer));
  RT_CHECK(vx_mem_address(src0_buffer, &kernel_arg.src0_addr));
  RT_CHECK(vx_mem_alloc(device, buf_size, VX_MEM_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_address(dst_buffer, &kernel_arg.dst_addr));

  std::vector<TYPE> h_src0(num_points);
  for (uint32_t i = 0; i < num_points; ++i) {
    h_src0[i] = Compare<TYPE>::gen();
  }
  RT_CHECK(vx_copy_to_dev(src0_buffer, h_src0.data(), 0, buf_size));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
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

  stats.report("dropout", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          "dropout")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "dropout", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
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
