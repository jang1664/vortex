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
static uint32_t QBLK = 32;
static uint32_t QDIR = 0;
static uint32_t GEMM_QDIR = 0;
static uint32_t SOURCE_TRANSPOSED = 0;

static vx_device_h device = nullptr;
static vx_buffer_h kernel_bin = nullptr;
static vx_buffer_h args_buf = nullptr;
static vx_buffer_h src_buf = nullptr;
static vx_buffer_h dst_buf = nullptr;

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _rc = (_expr);                                                      \
    if (_rc == 0) break;                                                    \
    printf("Error: '%s' returned %d\n", #_expr, _rc);                      \
    cleanup();                                                              \
    exit(1);                                                                \
  } while (0)

static void cleanup() {
  if (src_buf) vx_mem_free(src_buf);
  if (dst_buf) vx_mem_free(dst_buf);
  if (args_buf) vx_mem_free(args_buf);
  if (kernel_bin) vx_mem_free(kernel_bin);
  if (device) vx_dev_close(device);
}

static void show_usage(const char* prog) {
  printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
         "[--output=PATH] [--output-append] [-k K] [-n N] [-q QBLK] "
         "[-d QDIR] [--gemm-qdir QDIR] [--source-transposed]\n", prog);
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

static uint32_t output_K() {
  const uint32_t logical = SOURCE_TRANSPOSED ? N : K;
  uint32_t align = TILE_DMA_MXU_KT;
  if (GEMM_QDIR == 0 && QBLK > align) align = QBLK;
  return align_up(logical, align);
}

static uint32_t output_N() {
  const uint32_t logical = SOURCE_TRANSPOSED ? K : N;
  uint32_t align = TILE_DMA_MXU_NT;
  if (GEMM_QDIR == 1 && QBLK > align) align = QBLK;
  return align_up(logical, align);
}

static uint32_t slot_body_bytes(uint32_t ck, uint32_t cn) {
  const uint32_t ng_per_mxu_nt = (TILE_DMA_MXU_NT + QBLK - 1) / QBLK;
  if (GEMM_QDIR == 0) {
    return (ck / QBLK) * cn * TILE_ELEM_BYTES;
  }
  return (cn / TILE_DMA_MXU_NT) * ck * ng_per_mxu_nt * TILE_ELEM_BYTES;
}

static uint32_t slot_bytes_for(uint32_t ck, uint32_t cn) {
  return align_up(slot_body_bytes(ck, cn), TILE_SCALE_SLOT_ALIGN);
}

static void compute_slot_layout(uint32_t& total_bytes,
                                uint32_t& nt_dma_count,
                                uint32_t& slot_fk_fn,
                                uint32_t& slot_fk_pn,
                                uint32_t& slot_pk_fn,
                                uint32_t& per_kt_full_K,
                                uint32_t& max_slot_bytes) {
  const uint32_t out_k = output_K();
  const uint32_t out_n = output_N();
  const uint32_t k_tiles = (out_k + TILE_DMA_KT - 1) / TILE_DMA_KT;
  nt_dma_count = (out_n + TILE_DMA_NT - 1) / TILE_DMA_NT;
  const uint32_t ck_last = (out_k - (k_tiles - 1) * TILE_DMA_KT < TILE_DMA_KT)
                             ? (out_k - (k_tiles - 1) * TILE_DMA_KT)
                             : TILE_DMA_KT;
  const uint32_t cn_last = (out_n - (nt_dma_count - 1) * TILE_DMA_NT < TILE_DMA_NT)
                             ? (out_n - (nt_dma_count - 1) * TILE_DMA_NT)
                             : TILE_DMA_NT;

  slot_fk_fn = slot_bytes_for(TILE_DMA_KT, TILE_DMA_NT);
  slot_fk_pn = slot_bytes_for(TILE_DMA_KT, cn_last);
  slot_pk_fn = slot_bytes_for(ck_last, TILE_DMA_NT);
  per_kt_full_K = (nt_dma_count - 1) * slot_fk_fn + slot_fk_pn;

  total_bytes = 0;
  max_slot_bytes = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t ck = (out_k - kt * TILE_DMA_KT < TILE_DMA_KT)
                          ? (out_k - kt * TILE_DMA_KT)
                          : TILE_DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < nt_dma_count; ++nt_dma) {
      const uint32_t cn = (out_n - nt_dma * TILE_DMA_NT < TILE_DMA_NT)
                            ? (out_n - nt_dma * TILE_DMA_NT)
                            : TILE_DMA_NT;
      const uint32_t slot = slot_bytes_for(ck, cn);
      total_bytes += slot;
      if (slot > max_slot_bytes) max_slot_bytes = slot;
    }
  }
}

static void parse_args(int argc, char** argv) {
  bool gemm_qdir_set = false;
  static struct option long_opts[] = {
    {"gemm-qdir", required_argument, nullptr, 1000},
    {"source-transposed", no_argument, nullptr, 1001},
    {nullptr, 0, nullptr, 0},
  };
  int c;
  while ((c = getopt_long(argc, argv, "k:n:q:d:h", long_opts, nullptr)) != -1) {
    switch (c) {
      case 'k': K = atoi(optarg); break;
      case 'n': N = atoi(optarg); break;
      case 'q': QBLK = atoi(optarg); break;
      case 'd': QDIR = atoi(optarg); break;
      case 1000: GEMM_QDIR = atoi(optarg); gemm_qdir_set = true; break;
      case 1001: SOURCE_TRANSPOSED = 1; break;
      case 'h': show_usage(argv[0]); exit(0);
      default: show_usage(argv[0]); exit(1);
    }
  }
  if (!gemm_qdir_set) GEMM_QDIR = QDIR;
}

int main(int argc, char** argv) {
  auto bench = vx_bench::parse(argc, argv);
  parse_args(argc, argv);

  if (!is_pow2(TILE_DMA_KT) || !is_pow2(TILE_DMA_NT) ||
      !is_pow2(TILE_DMA_MXU_NT) || !is_pow2(QBLK)) {
    printf("ERROR: tile constants and QBLK must be powers of two\n");
    return 1;
  }
  if (QDIR > 1 || GEMM_QDIR > 1) {
    printf("ERROR: source_QDIR and gemm_QDIR must be 0 or 1\n");
    return 1;
  }
  if (K == 0 || N == 0) {
    printf("ERROR: K and N must be non-zero\n");
    return 1;
  }

  uint32_t total_bytes = 0;
  uint32_t nt_dma_count = 0;
  uint32_t slot_fk_fn = 0;
  uint32_t slot_fk_pn = 0;
  uint32_t slot_pk_fn = 0;
  uint32_t per_kt_full_K = 0;
  uint32_t max_slot_bytes = 0;
  compute_slot_layout(total_bytes, nt_dma_count, slot_fk_fn, slot_fk_pn,
                      slot_pk_fn, per_kt_full_K, max_slot_bytes);

  uint32_t src_rows = 0;
  uint32_t src_cols = 0;
  if (QDIR == 0) {
    src_rows = (K + QBLK - 1) / QBLK;
    src_cols = N;
  } else {
    src_rows = K;
    src_cols = (N + QBLK - 1) / QBLK;
  }
  const size_t src_elems = size_t(src_rows) * src_cols;
  std::vector<uint16_t> h_src(src_elems);
  for (size_t i = 0; i < src_elems; ++i) {
    h_src[i] = uint16_t(i & 0xffff);
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(uint16_t), VX_MEM_READ, &src_buf));
  RT_CHECK(vx_mem_alloc(device, total_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_elems * sizeof(uint16_t)));

  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  if (num_threads == 0) {
    printf("ERROR: VX_CAPS_NUM_THREADS returned 0\n");
    cleanup();
    return 1;
  }
  const uint32_t tpb = uint32_t(num_threads);
  const uint32_t out_k = output_K();
  const uint32_t k_tiles = (out_k + TILE_DMA_KT - 1) / TILE_DMA_KT;
  const uint32_t ng_per_mxu_nt = (TILE_DMA_MXU_NT + QBLK - 1) / QBLK;
  const uint32_t slot_elems = max_slot_bytes / TILE_ELEM_BYTES;
  const uint32_t blocks_x = (slot_elems + tpb - 1) / tpb;

  kernel_arg_t karg = {};
  karg.grid_dim[0] = blocks_x;
  karg.grid_dim[1] = nt_dma_count;
  karg.grid_dim[2] = k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.K = K;
  karg.N = N;
  karg.QBLK = QBLK;
  karg.QDIR = QDIR;
  karg.GEMM_QDIR = GEMM_QDIR;
  karg.SOURCE_TRANSPOSED = SOURCE_TRANSPOSED;
  karg.k_tiles = k_tiles;
  karg.n_dma_tiles = nt_dma_count;
  karg.slot_fk_fn = slot_fk_fn;
  karg.slot_fk_pn = slot_fk_pn;
  karg.slot_pk_fn = slot_pk_fn;
  karg.per_kt_full_K = per_kt_full_K;
  karg.max_slot_bytes = max_slot_bytes;
  karg.log2_kt = log2_u32(TILE_DMA_KT);
  karg.log2_nt = log2_u32(TILE_DMA_NT);
  karg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  karg.log2_ng_per_mxu_nt = (GEMM_QDIR == 1) ? log2_u32(ng_per_mxu_nt) : 0;
  karg.log2_qblk = log2_u32(QBLK);

  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));

  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, kernel_bin, args_buf));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
  }

  stats.report("tile_scale_zp_w4a16", bench);
  cleanup();
  return 0;
}
