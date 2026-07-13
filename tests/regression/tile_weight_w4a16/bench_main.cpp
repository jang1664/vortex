#include "common.h"
#include "bench_util.h"
#include <vortex.h>
#include <getopt.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t K = 64;
static uint32_t N = 64;
static uint32_t WTRANS = 0;
static uint32_t SOURCE_TRANSPOSED = 0;

static vx_device_h device = nullptr;
static vx_buffer_h kernel_bin = nullptr;
static vx_buffer_h args_buf = nullptr;
static vx_buffer_h src_buf = nullptr;
static vx_buffer_h dst_buf = nullptr;

static void cleanup() {
  if (src_buf) vx_mem_free(src_buf);
  if (dst_buf) vx_mem_free(dst_buf);
  if (args_buf) vx_mem_free(args_buf);
  if (kernel_bin) vx_mem_free(kernel_bin);
  if (device) vx_dev_close(device);
}

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _rc = (_expr);                                                      \
    if (_rc == 0) break;                                                    \
    printf("Error: '%s' returned %d\n", #_expr, _rc);                      \
    cleanup();                                                              \
    exit(1);                                                                \
  } while (0)

static void show_usage(const char* prog) {
  printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
         "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-k K] [-n N] [-t WTRANS] "
         "[--source-transposed]\n", prog);
}

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint32_t align_up(uint32_t a, uint32_t b) {
  return ((a + b - 1) / b) * b;
}

static void parse_args(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--help") == 0) {
      show_usage(argv[0]);
      exit(0);
    }
  }

  static struct option long_opts[] = {
    {"source-transposed", no_argument, nullptr, 1000},
    {nullptr, 0, nullptr, 0},
  };
  int c;
  while ((c = getopt_long(argc, argv, "k:n:t:h", long_opts, nullptr)) != -1) {
    switch (c) {
      case 'k': K = atoi(optarg); break;
      case 'n': N = atoi(optarg); break;
      case 't': WTRANS = atoi(optarg); break;
      case 1000: SOURCE_TRANSPOSED = 1; break;
      case 'h': show_usage(argv[0]); exit(0);
      default: show_usage(argv[0]); exit(1);
    }
  }
}

int main(int argc, char** argv) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  parse_args(argc, argv);

  if (K == 0 || N == 0 || (N & 1)) {
    printf("ERROR: K,N must be non-zero and N must be even.\n");
    return 1;
  }
  if (WTRANS > 1) {
    printf("ERROR: WTRANS must be 0 or 1\n");
    return 1;
  }
  if (SOURCE_TRANSPOSED && WTRANS == 0) {
    printf("ERROR: --source-transposed requires WTRANS=1\n");
    return 1;
  }
  if (!is_pow2(TILE_DMA_KT) || !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  const uint32_t out_K = SOURCE_TRANSPOSED ? align_up(N, TILE_DMA_MXU_KT)
                                           : align_up(K, TILE_DMA_MXU_KT);
  const uint32_t out_N = SOURCE_TRANSPOSED ? align_up(K, TILE_DMA_MXU_NT)
                                           : align_up(N, TILE_DMA_MXU_NT);
  const size_t src_bytes = size_t(K) * (N / 2);
  const size_t dst_bytes = size_t(out_K) * (out_N / 2);
  std::vector<uint8_t> h_src(src_bytes);
  for (size_t i = 0; i < h_src.size(); ++i) {
    h_src[i] = uint8_t(i & 0xff);
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, src_bytes, VX_MEM_READ, &src_buf));
  RT_CHECK(vx_mem_alloc(device, dst_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_bytes));

  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  if (num_threads == 0) {
    printf("ERROR: VX_CAPS_NUM_THREADS returned 0\n");
    cleanup();
    return 1;
  }
  const uint32_t threads_per_block = uint32_t(num_threads);
  const uint32_t logical_K = out_K;
  const uint32_t logical_N = out_N;
  const uint32_t k_tiles = (logical_K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  const uint32_t max_cur_k = (logical_K < TILE_DMA_KT) ? logical_K : TILE_DMA_KT;
  const uint32_t cur_kb = max_cur_k / TILE_DMA_MXU_KT;
  const uint32_t n_tiles = logical_N / TILE_DMA_MXU_NT;
  const uint32_t chunks_per_nt_kt = (WTRANS == 0)
                                      ? (cur_kb * TILE_DMA_MXU_KT)
                                      : (cur_kb * TILE_DMA_MXU_NT * (TILE_DMA_MXU_KT / 2));

  kernel_arg_t karg = {};
  karg.grid_dim[0] = (chunks_per_nt_kt + threads_per_block - 1) / threads_per_block;
  karg.grid_dim[1] = n_tiles;
  karg.grid_dim[2] = k_tiles;
  karg.block_dim[0] = threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.K = K;
  karg.N = N;
  karg.WTRANS = WTRANS;
  karg.SOURCE_TRANSPOSED = SOURCE_TRANSPOSED;
  karg.log2_kt = log2_u32(TILE_DMA_KT);
  karg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  karg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  karg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.start()) {
    cleanup();
    return -1;
  }
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
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

  stats.report("tile_weight_w4a16", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, karg, args_buf, first_latency_us, first_iter_perf,
          "tile_weight_w4a16")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "tile_weight_w4a16", bench, device, kernel_bin, args_buf, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
