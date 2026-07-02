// Benchmark harness for rmsnorm. See softmax/bench_main.cpp for design notes.

#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <assert.h>
#include <vortex.h>
#include "common.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h gamma_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (gamma_buffer) vx_mem_free(gamma_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& v : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;
    v = float_to_fp16(x);
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  uint32_t batch_size = 2;
  uint32_t seq_len = 8;
  uint32_t hidden_dim = 128;
  float eps = 1e-6f;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0)       batch_size = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0)    seq_len    = atoi(argv[++i]);
    else if (strcmp(argv[i], "-hidden") == 0) hidden_dim = atoi(argv[++i]);
    else if (strcmp(argv[i], "-eps") == 0)    eps        = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
             "[-batch N] [-seq S] [-hidden H] [-eps E]\n", argv[0]);
      return 0;
    }
  }

  if (!bench.csv) {
    printf("RMSNorm Bench: batch=%u seq=%u hidden=%u eps=%e  warmup=%d iterations=%d\n",
           batch_size, seq_len, hidden_dim, eps, bench.warmup, bench.iterations);
  }

  uint32_t total_tokens = batch_size * seq_len;
  uint32_t input_size = total_tokens * hidden_dim;
  std::vector<data_t> h_in(input_size), h_gamma(hidden_dim);
  srand(42);
  initialize_random(h_in);
  initialize_random(h_gamma);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t input_bytes = input_size * sizeof(data_t);
  uint32_t gamma_bytes = hidden_dim * sizeof(data_t);
  uint32_t output_bytes = input_size * sizeof(data_t);
  RT_CHECK(vx_mem_alloc(device, input_bytes,  VX_MEM_READ,  &input_buffer));
  RT_CHECK(vx_mem_alloc(device, gamma_bytes,  VX_MEM_READ,  &gamma_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(),    0, input_bytes));
  RT_CHECK(vx_copy_to_dev(gamma_buffer, h_gamma.data(), 0, gamma_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_RMSNORM;
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  kernel_arg.grid_dim[0] = total_tokens;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer,  &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(gamma_buffer,  &kernel_arg.gamma_addr));
  kernel_arg.batch_size = batch_size;
  kernel_arg.seq_len = seq_len;
  kernel_arg.hidden_dim = hidden_dim;
  kernel_arg.eps = eps;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
    vx_bench::dump_iteration_perf(device, bench, i);
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  stats.report("rmsnorm", bench);

  if (!vx_bench::run_power_measurement(
          "rmsnorm", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
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
