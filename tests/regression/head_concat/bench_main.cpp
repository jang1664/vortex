#include "common.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _ret = _expr;                                                       \
    if (0 == _ret)                                                          \
      break;                                                                \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);                \
    cleanup();                                                              \
    exit(-1);                                                               \
  } while (false)

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void init_input(std::vector<data_t>& input) {
  for (size_t i = 0; i < input.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    input[i] = float_to_fp16(float(x) / 80.0f);
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  uint32_t batch = 1;
  uint32_t seq = 128;
  uint32_t heads = 32;
  uint32_t headdim = 128;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0) seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-headdim") == 0) headdim = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] "
             "[-batch B] [-seq S] [-heads H] [-headdim D]\n", argv[0]);
      return 0;
    }
  }

  const uint32_t hidden = heads * headdim;
  const size_t elems = (size_t)batch * seq * hidden;
  const size_t bytes = elems * sizeof(data_t);
  std::vector<data_t> h_input;
  if (bench.copy_inputs) {
    h_input.resize(elems);
    init_input(h_input);
  }

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, bytes, VX_MEM_WRITE, &output_buffer));
  if (bench.copy_inputs) {
    RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, bytes));
  }

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t blocks = std::min(
      (uint32_t)((elems + tpb - 1) / tpb),
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_HEAD_CONCAT;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.batch = batch;
  arg.seq = seq;
  arg.heads = heads;
  arg.headdim = headdim;
  arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

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

  stats.report("head_concat", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "head_concat")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "head_concat", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
