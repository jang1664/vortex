#include "common.h"
#include "bench_util.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t M = 4;
static uint32_t K = 64;

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
         "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-m M] [-k K]\n", prog);
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

  int c;
  while ((c = getopt(argc, argv, "m:k:h")) != -1) {
    switch (c) {
      case 'm': M = atoi(optarg); break;
      case 'k': K = atoi(optarg); break;
      case 'h': show_usage(argv[0]); exit(0);
      default: show_usage(argv[0]); exit(1);
    }
  }
}

static bool validate_tile_params() {
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) || !is_pow2(TILE_DMA_MXU_KT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return false;
  }
  if (TILE_DMA_KT % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: KT must be divisible by MXU_KT\n");
    return false;
  }
  return true;
}

int main(int argc, char** argv) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  parse_args(argc, argv);

  const uint32_t M_pad = (M + 7u) & ~7u;
  if (!validate_tile_params()) return 1;
  const uint32_t K_pad = align_up(K, TILE_DMA_MXU_KT);

  std::vector<uint16_t> h_src(size_t(M) * K);
  for (size_t i = 0; i < h_src.size(); ++i) {
    h_src[i] = uint16_t((i + 1) & 0xffff);
  }

  const size_t src_bytes = h_src.size() * TILE_ELEM_BYTES;
  const size_t dst_bytes = size_t(M_pad) * K_pad * TILE_ELEM_BYTES;

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
  const uint32_t tpb = uint32_t(num_threads);
  const uint32_t k_tiles = (K_pad + TILE_DMA_KT - 1) / TILE_DMA_KT;
  const uint32_t k_mic = TILE_DMA_KT / TILE_DMA_MXU_KT;
  const uint32_t chunks_per_row = TILE_DMA_MXU_KT / 2;
  const uint32_t chunks_per_kb = M_pad * chunks_per_row;
  const uint32_t blocks_x = (chunks_per_kb + tpb - 1) / tpb;

  kernel_arg_t karg = {};
  karg.grid_dim[0] = blocks_x;
  karg.grid_dim[1] = k_mic;
  karg.grid_dim[2] = k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.M_real = M;
  karg.M_pad = M_pad;
  karg.K_real = K;
  karg.K_pad = K_pad;
  karg.log2_mt = log2_u32(TILE_DMA_MT);
  karg.log2_kt = log2_u32(TILE_DMA_KT);
  karg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);

  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
    vx_bench::dump_iteration_perf(device, bench, i);
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  stats.report("tile_input_a", bench);

  if (!vx_bench::run_power_measurement(
          "tile_input_a", bench, device, kernel_bin, args_buf, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
