// Minimal standalone regression test for tile_scale_zp_w4a16.
//
// Builds a small synthetic 2-D source tensor (uint16-shaped bytes), runs the
// kernel on device, copies the output back, and verifies byte-for-byte
// against a CPU reference that mirrors
//   tests/regression/fpint_gemm_ffn_hw/main.cpp::convert_scale_tiled
//
// Usage: ./tile_scale_zp_w4a16 [-k K] [-n N] [-q QBLK] [-d QDIR]
//                              [--mt MT] [--kt KT] [--nt NT]
//                              [--gemm-qdir QDIR] [--source-transposed]

#include "common.h"
#include <vortex.h>
#include <getopt.h>
#include <unistd.h>
#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t K    = 64;
static uint32_t N    = 64;
static uint32_t QBLK = 32;
static uint32_t DMA_MT = DEFAULT_DMA_MT;
static uint32_t DMA_KT = DEFAULT_DMA_KT;
static uint32_t DMA_NT = DEFAULT_DMA_NT;
static uint32_t QDIR = 0;
static uint32_t GEMM_QDIR = 0;
static uint32_t SOURCE_TRANSPOSED = 0;

static const char* kernel_file = "kernel.vxbin";
static vx_device_h device     = nullptr;
static vx_buffer_h kernel_bin = nullptr;
static vx_buffer_h args_buf   = nullptr;
static vx_buffer_h src_buf    = nullptr;
static vx_buffer_h dst_buf    = nullptr;

#define RT_CHECK(_expr)                                                       \
  do {                                                                        \
    int _rc = (_expr);                                                        \
    if (_rc != 0) {                                                           \
      printf("Error: '%s' returned %d\n", #_expr, _rc);                       \
      exit(1);                                                                \
    }                                                                         \
  } while (0)

static void cleanup() {
  if (src_buf)    vx_mem_free(src_buf);
  if (dst_buf)    vx_mem_free(dst_buf);
  if (args_buf)   vx_mem_free(args_buf);
  if (kernel_bin) vx_mem_free(kernel_bin);
  if (device)     vx_dev_close(device);
}

static void show_usage() {
  printf("Usage: ./tile_scale_zp_w4a16 [-k K] [-n N] [-q QBLK] [-d QDIR] "
         "[--mt MT] [--kt KT] [--nt NT] "
         "[--gemm-qdir QDIR] [--source-transposed]\n");
}

static void parse_args(int argc, char** argv) {
  bool gemm_qdir_set = false;
  static struct option long_opts[] = {
    {"gemm-qdir", required_argument, nullptr, 1000},
    {"source-transposed", no_argument, nullptr, 1001},
    {"mt", required_argument, nullptr, 1002},
    {"kt", required_argument, nullptr, 1003},
    {"nt", required_argument, nullptr, 1004},
    {nullptr, 0, nullptr, 0},
  };
  int c;
  while ((c = getopt_long(argc, argv, "k:n:q:d:h", long_opts, nullptr)) != -1) {
    switch (c) {
      case 'k': K    = atoi(optarg); break;
      case 'n': N    = atoi(optarg); break;
      case 'q': QBLK = atoi(optarg); break;
      case 'd': QDIR = atoi(optarg); break;
      case 1000: GEMM_QDIR = atoi(optarg); gemm_qdir_set = true; break;
      case 1001: SOURCE_TRANSPOSED = 1; break;
      case 1002: DMA_MT = atoi(optarg); break;
      case 1003: DMA_KT = atoi(optarg); break;
      case 1004: DMA_NT = atoi(optarg); break;
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
  if (!gemm_qdir_set) GEMM_QDIR = QDIR;
}

static uint32_t align_up_pow2(uint32_t a, uint32_t b) {
  return (a + b - 1u) & ~(b - 1u);
}

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint32_t ceil_div_pow2(uint32_t a, uint32_t b) {
  return (a + b - 1u) >> log2_u32(b);
}

static uint32_t output_K() {
  const uint32_t logical = SOURCE_TRANSPOSED ? N : K;
  uint32_t align = TILE_DMA_MXU_KT;
  if (GEMM_QDIR == 0 && QBLK > align) align = QBLK;
  return align_up_pow2(logical, align);
}

static uint32_t output_N() {
  const uint32_t logical = SOURCE_TRANSPOSED ? K : N;
  uint32_t align = TILE_DMA_MXU_NT;
  if (GEMM_QDIR == 1 && QBLK > align) align = QBLK;
  return align_up_pow2(logical, align);
}

static uint32_t slot_body_bytes(uint32_t ck, uint32_t cn) {
  const uint32_t MXU_NT = TILE_DMA_MXU_NT;
  const uint32_t ng_per_mxu_nt = ceil_div_pow2(MXU_NT, QBLK);

  if (GEMM_QDIR == 0) {
    return (ck >> log2_u32(QBLK)) * cn * TILE_ELEM_BYTES;
  }
  return (cn >> log2_u32(MXU_NT)) * ck * ng_per_mxu_nt * TILE_ELEM_BYTES;
}

static uint32_t slot_bytes_for(uint32_t ck, uint32_t cn) {
  return align_up_pow2(slot_body_bytes(ck, cn), TILE_SCALE_SLOT_ALIGN);
}

static void compute_slot_layout(uint32_t& total_bytes, uint32_t& nt_dma_count,
                                uint32_t& slot_fk_fn, uint32_t& slot_fk_pn,
                                uint32_t& slot_pk_fn, uint32_t& per_kt_full_K,
                                uint32_t& max_slot_bytes) {
  const uint32_t out_k = output_K();
  const uint32_t out_n = output_N();
  const uint32_t k_tiles = ceil_div_pow2(out_k, DMA_KT);
  nt_dma_count = ceil_div_pow2(out_n, DMA_NT);
  const uint32_t ck_last = (out_k - (k_tiles - 1) * DMA_KT < DMA_KT)
                             ? (out_k - (k_tiles - 1) * DMA_KT) : DMA_KT;
  const uint32_t cn_last = (out_n - (nt_dma_count - 1) * DMA_NT < DMA_NT)
                             ? (out_n - (nt_dma_count - 1) * DMA_NT) : DMA_NT;

  slot_fk_fn = slot_bytes_for(DMA_KT, DMA_NT);
  slot_fk_pn = slot_bytes_for(DMA_KT, cn_last);
  slot_pk_fn = slot_bytes_for(ck_last, DMA_NT);
  per_kt_full_K = (nt_dma_count - 1) * slot_fk_fn + slot_fk_pn;

  total_bytes = 0;
  max_slot_bytes = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = (out_k - kt * DMA_KT < DMA_KT) ? (out_k - kt * DMA_KT)
                                                 : DMA_KT;
    for (uint32_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
      uint32_t cn = (out_n - nt_dma * DMA_NT < DMA_NT) ? (out_n - nt_dma * DMA_NT)
                                                       : DMA_NT;
      uint32_t slot = slot_bytes_for(ck, cn);
      total_bytes += slot;
      if (slot > max_slot_bytes) max_slot_bytes = slot;
    }
  }
}

static uint16_t source_qparam_value(const std::vector<uint16_t>& src,
                                    uint32_t out_k,
                                    uint32_t out_n) {
  const uint32_t source_row = SOURCE_TRANSPOSED ? out_n : out_k;
  const uint32_t source_col = SOURCE_TRANSPOSED ? out_k : out_n;
  if (source_row >= K || source_col >= N) {
    return 0;
  }
  if (QDIR == 0) {
    return src[(source_row >> log2_u32(QBLK)) * N + source_col];
  }
  const uint32_t ng_total = ceil_div_pow2(N, QBLK);
  return src[source_row * ng_total + (source_col >> log2_u32(QBLK))];
}

// CPU reference reorder (mirrors GEMM-facing qparam slot layout).
static void cpu_tile_scale_zp(const std::vector<uint16_t>& src,
                              std::vector<uint8_t>& dst,
                              uint32_t total_bytes, uint32_t nt_dma_count) {
  const uint32_t MXU_NT = TILE_DMA_MXU_NT;
  const uint32_t mxu_per_dma_nt = DMA_NT >> log2_u32(MXU_NT);
  const uint32_t out_k_total = output_K();
  const uint32_t out_n_total = output_N();
  const uint32_t k_tiles      = ceil_div_pow2(out_k_total, DMA_KT);
  const uint32_t ng_per_mxu_nt = ceil_div_pow2(MXU_NT, QBLK);

  dst.assign(total_bytes, 0);
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = (out_k_total - kt * DMA_KT < DMA_KT)
                       ? (out_k_total - kt * DMA_KT) : DMA_KT;
    uint32_t cur_groups = cur_k >> log2_u32(QBLK);
    for (uint32_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
      uint32_t n_start = nt_dma * DMA_NT;
      uint32_t cur_n_dma = (out_n_total - n_start < DMA_NT)
                             ? (out_n_total - n_start) : DMA_NT;
      uint32_t cur_nb = cur_n_dma >> log2_u32(MXU_NT);
      uint32_t body_off = 0;
      for (uint32_t i = 0; i < kt; i++) {
        uint32_t ck_prev = (out_k_total - i * DMA_KT < DMA_KT)
                             ? (out_k_total - i * DMA_KT) : DMA_KT;
        for (uint32_t j = 0; j < nt_dma_count; j++) {
          uint32_t cn_prev = (out_n_total - j * DMA_NT < DMA_NT)
                               ? (out_n_total - j * DMA_NT) : DMA_NT;
          body_off += slot_bytes_for(ck_prev, cn_prev);
        }
      }
      for (uint32_t j = 0; j < nt_dma; j++) {
        uint32_t cn_prev = (out_n_total - j * DMA_NT < DMA_NT)
                             ? (out_n_total - j * DMA_NT) : DMA_NT;
        body_off += slot_bytes_for(cur_k, cn_prev);
      }

      if (GEMM_QDIR == 0) {
        for (uint32_t nb = 0; nb < cur_nb; nb++) {
          for (uint32_t g = 0; g < cur_groups; g++) {
            for (uint32_t col = 0; col < MXU_NT; col++) {
              uint32_t out_k = kt * DMA_KT + (g << log2_u32(QBLK));
              uint32_t out_n = n_start + (nb << log2_u32(MXU_NT)) + col;
              uint16_t v = source_qparam_value(src, out_k, out_n);
              dst[body_off + 0] = uint8_t(v & 0xFF);
              dst[body_off + 1] = uint8_t((v >> 8) & 0xFF);
              body_off += 2;
            }
          }
        }
      } else {
        for (uint32_t nb = 0; nb < cur_nb; nb++) {
          uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
          uint32_t ng_start = (global_nt_mxu << log2_u32(MXU_NT)) >> log2_u32(QBLK);
          for (uint32_t k = 0; k < cur_k; k++) {
            for (uint32_t ng = 0; ng < ng_per_mxu_nt; ng++) {
              uint32_t out_k = kt * DMA_KT + k;
              uint32_t out_n = (ng_start + ng) << log2_u32(QBLK);
              uint16_t v = source_qparam_value(src, out_k, out_n);
              dst[body_off + 0] = uint8_t(v & 0xFF);
              dst[body_off + 1] = uint8_t((v >> 8) & 0xFF);
              body_off += 2;
            }
          }
        }
      }
    }
  }
}

int main(int argc, char** argv) {
  parse_args(argc, argv);
  printf("tile_scale_zp_w4a16  K=%u N=%u QBLK=%u source_QDIR=%u gemm_QDIR=%u source_transposed=%u\n",
         K, N, QBLK, QDIR, GEMM_QDIR, SOURCE_TRANSPOSED);

  if (!is_pow2(DMA_MT) || !is_pow2(DMA_KT) || !is_pow2(DMA_NT) ||
      !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT) || !is_pow2(QBLK)) {
    printf("ERROR: MT, KT, NT, MXU tiles, and QBLK must be powers of two\n");
    return 1;
  }
  if ((DMA_KT & (TILE_DMA_MXU_KT - 1u)) != 0 ||
      (DMA_NT & (TILE_DMA_MXU_NT - 1u)) != 0) {
    printf("ERROR: KT must be divisible by MXU_KT and NT by MXU_NT\n");
    return 1;
  }
  if (GEMM_QDIR == 0 && DMA_KT < QBLK) {
    printf("ERROR: GEMM_QDIR=0 requires KT >= QBLK\n");
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
  const uint32_t out_k = output_K();

  uint32_t total_bytes, nt_dma_count, slot_fk_fn, slot_fk_pn, slot_pk_fn;
  uint32_t per_kt_full_K, max_slot_bytes;
  compute_slot_layout(total_bytes, nt_dma_count, slot_fk_fn, slot_fk_pn,
                      slot_pk_fn, per_kt_full_K, max_slot_bytes);
  printf("  total_bytes=%u  nt_dma_count=%u  max_slot_bytes=%u\n",
         total_bytes, nt_dma_count, max_slot_bytes);

  // Build synthetic 2-D source [rows, cols] of uint16 values.
  uint32_t src_rows, src_cols;
  if (QDIR == 0) { src_rows = ceil_div_pow2(K, QBLK); src_cols = N; }
  else           { src_rows = K;        src_cols = ceil_div_pow2(N, QBLK); }
  size_t src_elems = size_t(src_rows) * src_cols;
  std::vector<uint16_t> h_src(src_elems);
  for (size_t i = 0; i < src_elems; i++) h_src[i] = uint16_t(i & 0xFFFF);

  // CPU reference.
  std::vector<uint8_t> h_ref;
  cpu_tile_scale_zp(h_src, h_ref, total_bytes, nt_dma_count);

  // Device run.
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(uint16_t), VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, total_bytes,                  VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_elems * sizeof(uint16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t flat_mode =
      SOURCE_TRANSPOSED != 0 && QDIR == 1 && GEMM_QDIR == 0
          && QBLK == N && N == DMA_KT
          && (K & (DMA_NT - 1u)) == 0
      ? 1u
      : (SOURCE_TRANSPOSED == 0 && QDIR == 1 && GEMM_QDIR == 1
             && QBLK == N && is_pow2(N)
             && (N & (TILE_DMA_MXU_NT - 1u)) == 0
             && (K & (DMA_KT - 1u)) == 0
         ? 2u : 0u);
  uint32_t tpb = flat_mode != 0
      ? std::min(256u, uint32_t(num_warps * num_threads))
      : uint32_t(num_threads);

  uint32_t k_tiles = ceil_div_pow2(out_k, DMA_KT);
  uint32_t ng_per_mxu_nt = ceil_div_pow2(TILE_DMA_MXU_NT, QBLK);
  uint32_t slot_elems = max_slot_bytes / 2;
  uint32_t blocks_x = flat_mode != 0
      ? std::min(
            ((total_bytes / TILE_ELEM_BYTES) + tpb - 1u) / tpb,
            std::max(1u, uint32_t(num_cores) * 4u))
      : (slot_elems + tpb - 1) / tpb;

  kernel_arg_t karg = {};
  karg.grid_dim[0]  = blocks_x;
  karg.grid_dim[1]  = flat_mode != 0 ? 1u : nt_dma_count;
  karg.grid_dim[2]  = flat_mode != 0 ? 1u : k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.K            = K;
  karg.N            = N;
  karg.QBLK         = QBLK;
  karg.QDIR         = QDIR;
  karg.GEMM_QDIR    = GEMM_QDIR;
  karg.SOURCE_TRANSPOSED = SOURCE_TRANSPOSED;
  karg.k_tiles      = k_tiles;
  karg.n_dma_tiles  = nt_dma_count;
  karg.slot_fk_fn   = slot_fk_fn;
  karg.slot_fk_pn   = slot_fk_pn;
  karg.slot_pk_fn   = slot_pk_fn;
  karg.per_kt_full_K = per_kt_full_K;
  karg.max_slot_bytes = max_slot_bytes;
  karg.log2_kt       = log2_u32(DMA_KT);
  karg.log2_nt       = log2_u32(DMA_NT);
  karg.log2_mxu_nt   = log2_u32(TILE_DMA_MXU_NT);
  karg.log2_ng_per_mxu_nt = (GEMM_QDIR == 1) ? log2_u32(ng_per_mxu_nt) : 0;
  karg.log2_qblk          = log2_u32(QBLK);
  karg.flat_mode          = flat_mode;

  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));
  RT_CHECK(vx_start(device, kernel_bin, args_buf));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  std::vector<uint8_t> h_dst(total_bytes);
  RT_CHECK(vx_copy_from_dev(h_dst.data(), dst_buf, 0, total_bytes));

  size_t errors = 0;
  for (size_t i = 0; i < total_bytes; i++) {
    if (h_dst[i] != h_ref[i]) {
      if (errors < 8)
        printf("Mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
               i, unsigned(h_dst[i]), unsigned(h_ref[i]));
      errors++;
    }
  }
  cleanup();
  if (errors == 0) {
    printf("PASSED (%u bytes match)\n", total_bytes);
    return 0;
  } else {
    printf("FAILED (%zu / %u bytes mismatch)\n", errors, total_bytes);
    return 1;
  }
}
