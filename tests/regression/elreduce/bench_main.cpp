// Benchmark harness for elreduce. See softmax/bench_main.cpp for design notes.

#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <cfloat>
#include <assert.h>
#include <vortex.h>
#include "common.h"
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

using data_t = float;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& v : vec) v = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;
}

struct OpInfo {
  uint32_t kernel_id;
  const char* name;
};

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  uint32_t batch_size = 128;
  uint32_t reduce_dim = 512;
  uint32_t op_id = KERNEL_MEAN;

  OpInfo ops[] = {
    {KERNEL_MEAN, "mean"},
    {KERNEL_SUM,  "sum"},
    {KERNEL_MAX,  "max"},
    {KERNEL_MIN,  "min"},
  };

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-b") == 0) batch_size = atoi(argv[++i]);
    else if (strcmp(argv[i], "-r") == 0) reduce_dim = atoi(argv[++i]);
    else if (strcmp(argv[i], "-op") == 0) {
      const char* op_name = argv[++i];
      for (const auto& op : ops) {
        if (strcmp(op_name, op.name) == 0) { op_id = op.kernel_id; break; }
      }
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
             "[-b BATCH] [-r REDUCE] [-op mean|sum|max|min]\n", argv[0]);
      return 0;
    }
  }

  const OpInfo& cur = ops[op_id];
  char label[32];
  std::snprintf(label, sizeof(label), "elreduce.%s", cur.name);

  if (!bench.csv) {
    printf("Elreduce Bench: op=%s batch=%u reduce=%u  warmup=%d iterations=%d\n",
           cur.name, batch_size, reduce_dim, bench.warmup, bench.iterations);
  }

  uint32_t input_size = batch_size * reduce_dim;
  std::vector<data_t> h_in(input_size);
  srand(42);
  initialize_random(h_in);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t input_bytes = input_size * sizeof(data_t);
  uint32_t output_bytes = batch_size * sizeof(data_t);
  RT_CHECK(vx_mem_alloc(device, input_bytes,  VX_MEM_READ,  &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(), 0, input_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = op_id;
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t num_blocks = std::min((batch_size + threads_per_block - 1) / threads_per_block,
                                 (uint32_t)num_cores * 4);
  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer,  &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.batch_size = batch_size;
  kernel_arg.reduce_dim = reduce_dim;
  kernel_arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

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

  stats.report(label, bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, kernel_arg, args_buffer, first_latency_us, first_iter_perf,
          label)) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          label, bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
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
