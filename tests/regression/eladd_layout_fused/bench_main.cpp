#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
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
vx_buffer_h input_a_buffer = nullptr;
vx_buffer_h input_b_buffer = nullptr;
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
  if (input_a_buffer) vx_mem_free(input_a_buffer);
  if (input_b_buffer) vx_mem_free(input_b_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static void init_values(std::vector<data_t>& values, float scale) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    values[i] = float_to_fp16(scale * float(x) / 64.0f);
  }
}

static void pack_gemm_c_tiled(const std::vector<data_t>& row,
                              std::vector<data_t>& tiled,
                              uint32_t M,
                              uint32_t M_pad,
                              uint32_t K) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  std::fill(tiled.begin(), tiled.end(), 0.0f);
  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t k = 0; k < K; ++k) {
      tiled[gemm_c_tiled_elem_offset(m, k, M_pad, K, log2_mt, log2_mxu_nt)] =
          row[(uint64_t)m * K + k];
    }
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  uint32_t M = 4;
  uint32_t K = 4096;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-m") == 0) M = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-m M] [-k K]\n", argv[0]);
      return 0;
    }
  }

  const uint32_t M_pad = (M + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const size_t row_elems = (size_t)M * K;
  const size_t tiled_elems = (size_t)M_pad * K;
  const size_t row_bytes = row_elems * sizeof(data_t);
  const size_t tiled_bytes = tiled_elems * sizeof(data_t);

  std::vector<data_t> h_a_row(row_elems);
  std::vector<data_t> h_b(row_elems);
  std::vector<data_t> h_a_tiled(tiled_elems);
  init_values(h_a_row, 1.0f);
  init_values(h_b, 0.5f);
  pack_gemm_c_tiled(h_a_row, h_a_tiled, M, M_pad, K);

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_bytes, VX_MEM_READ, &input_a_buffer));
  RT_CHECK(vx_mem_alloc(device, row_bytes, VX_MEM_READ, &input_b_buffer));
  RT_CHECK(vx_mem_alloc(device, row_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_a_buffer, h_a_tiled.data(), 0, tiled_bytes));
  RT_CHECK(vx_copy_to_dev(input_b_buffer, h_b.data(), 0, row_bytes));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t blocks = std::min(
      (uint32_t)((row_elems + tpb - 1) / tpb),
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_ELADD_LAYOUT_FUSED;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_a_buffer, &arg.input_a_addr));
  RT_CHECK(vx_mem_address(input_b_buffer, &arg.input_b_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.M_real = M;
  arg.M_pad = M_pad;
  arg.K = K;
  arg.log2_mt = log2_u32(TILE_DMA_MT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
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

  stats.report("eladd_layout_fused", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "eladd_layout_fused")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "eladd_layout_fused", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
