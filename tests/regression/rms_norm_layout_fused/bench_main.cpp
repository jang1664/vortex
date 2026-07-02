// Benchmark harness for rms_norm_layout_fused.

#include "common.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h gamma_buffer = nullptr;
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
  if (gamma_buffer) vx_mem_free(gamma_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void initialize_input(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    float x = -1.0f + 2.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    vec[i] = float_to_fp16(x);
  }
}

static void initialize_gamma(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    float x = 0.5f + (float((i * 1597334677u) % 1000) / 2000.0f);
    vec[i] = float_to_fp16(x);
  }
}

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  uint32_t M = 4;
  uint32_t K = 4096;
  float eps = 1e-6f;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-m") == 0) M = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-eps") == 0) eps = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-m M] [-k K] [-eps E]\n", argv[0]);
      return 0;
    }
  }

  if (K % TILE_DMA_KT != 0) {
    printf("ERROR: K must be multiple of %u (got %u)\n", TILE_DMA_KT, K);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) || !is_pow2(TILE_DMA_MXU_KT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  uint32_t M_pad = (M + 7u) & ~7u;
  if (!bench.csv) {
    printf("RMSNorm layout fused bench: M=%u M_pad=%u K=%u eps=%e warmup=%d iterations=%d\n",
           M, M_pad, K, eps, bench.warmup, bench.iterations);
  }

  size_t input_elems = size_t(M) * K;
  size_t output_elems = size_t(M_pad) * K;
  uint32_t input_bytes = input_elems * sizeof(data_t);
  uint32_t output_bytes = output_elems * sizeof(data_t);
  uint32_t gamma_bytes = K * sizeof(data_t);

  std::vector<data_t> h_in(input_elems);
  std::vector<data_t> h_gamma(K);
  initialize_input(h_in);
  initialize_gamma(h_gamma);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, gamma_bytes, VX_MEM_READ, &gamma_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(gamma_buffer, h_gamma.data(), 0, gamma_bytes));

  uint64_t num_warps = 0, num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t tpb = 1;
  while ((tpb << 1) <= threads_per_block) tpb <<= 1;

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_RMSNORM_LAYOUT_FUSED;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(gamma_buffer, &kernel_arg.gamma_addr));
  kernel_arg.M_real = M;
  kernel_arg.M_pad = M_pad;
  kernel_arg.K = K;
  kernel_arg.eps = eps;
  kernel_arg.log2_mt = log2_u32(TILE_DMA_MT);
  kernel_arg.log2_kt = log2_u32(TILE_DMA_KT);
  kernel_arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  kernel_arg.grid_dim[0] = M;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = tpb;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

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

  stats.report("rms_norm_layout_fused", bench);

  if (!vx_bench::run_power_measurement(
          "rms_norm_layout_fused", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
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
