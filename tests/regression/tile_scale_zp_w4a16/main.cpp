// Minimal standalone regression test for tile_scale_zp_w4a16.
//
// Builds a small synthetic 2-D source tensor (uint16-shaped bytes), runs the
// kernel on device, copies the output back, and verifies byte-for-byte
// against a CPU reference that mirrors
//   tests/regression/fpint_gemm_ffn_hw/main.cpp::convert_scale_tiled
//
// Usage: ./tile_scale_zp_w4a16 [-k K] [-n N] [-q QBLK] [-d QDIR]

#include "common.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t K    = 64;
static uint32_t N    = 64;
static uint32_t QBLK = 32;
static uint32_t QDIR = 0;

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
  printf("Usage: ./tile_scale_zp_w4a16 [-k K] [-n N] [-q QBLK] [-d QDIR]\n");
}

static void parse_args(int argc, char** argv) {
  int c;
  while ((c = getopt(argc, argv, "k:n:q:d:h")) != -1) {
    switch (c) {
      case 'k': K    = atoi(optarg); break;
      case 'n': N    = atoi(optarg); break;
      case 'q': QBLK = atoi(optarg); break;
      case 'd': QDIR = atoi(optarg); break;
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
}

static uint32_t align_up(uint32_t a, uint32_t b) {
  return ((a + b - 1) / b) * b;
}

static void compute_slot_layout(uint32_t& body_bytes, uint32_t& slot_bytes,
                                uint32_t& total_bytes, uint32_t& nt_dma_count) {
  const uint32_t MXU_NT = TILE_DMA_MXU_NT;
  const uint32_t k_tiles      = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  const uint32_t cur_k        = (k_tiles == 1) ? K : TILE_DMA_KT;
  const uint32_t cur_groups   = cur_k / QBLK;
  const uint32_t ng_per_mxu_nt = (MXU_NT + QBLK - 1) / QBLK;
  nt_dma_count                 = (N + TILE_DMA_NT - 1) / TILE_DMA_NT;
  const uint32_t cur_n_dma    = (nt_dma_count == 1) ? N : TILE_DMA_NT;
  const uint32_t cur_nb       = cur_n_dma / MXU_NT;

  if (QDIR == 0) {
    body_bytes = cur_nb * cur_groups * MXU_NT * TILE_ELEM_BYTES;
  } else {
    body_bytes = cur_nb * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
  }
  slot_bytes  = align_up(body_bytes, TILE_SCALE_SLOT_ALIGN);
  total_bytes = k_tiles * nt_dma_count * slot_bytes;
}

// CPU reference reorder (mirrors convert_scale_tiled).
static void cpu_tile_scale_zp(const std::vector<uint16_t>& src,
                              std::vector<uint8_t>& dst,
                              uint32_t total_bytes, uint32_t slot_bytes,
                              uint32_t body_bytes, uint32_t nt_dma_count) {
  const uint32_t MXU_NT = TILE_DMA_MXU_NT;
  const uint32_t mxu_per_dma_nt = TILE_DMA_NT / MXU_NT;
  const uint32_t k_tiles      = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  const uint32_t ng_per_mxu_nt = (MXU_NT + QBLK - 1) / QBLK;
  const uint32_t ng_total      = (N + QBLK - 1) / QBLK;

  dst.assign(total_bytes, 0);
  size_t out_byte_off = 0;

  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = (K - kt * TILE_DMA_KT < TILE_DMA_KT) ? (K - kt * TILE_DMA_KT)
                                                          : TILE_DMA_KT;
    uint32_t cur_groups = cur_k / QBLK;
    for (uint32_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
      uint32_t n_start = nt_dma * TILE_DMA_NT;
      uint32_t cur_n_dma = (N - n_start < TILE_DMA_NT) ? (N - n_start) : TILE_DMA_NT;
      uint32_t cur_nb = cur_n_dma / MXU_NT;
      uint32_t body_off = out_byte_off;

      if (QDIR == 0) {
        for (uint32_t nb = 0; nb < cur_nb; nb++) {
          for (uint32_t g = 0; g < cur_groups; g++) {
            for (uint32_t col = 0; col < MXU_NT; col++) {
              uint32_t src_g = kt * (TILE_DMA_KT / QBLK) + g;
              uint32_t src_c = n_start + nb * MXU_NT + col;
              uint16_t v = src[src_g * N + src_c];
              dst[body_off + 0] = uint8_t(v & 0xFF);
              dst[body_off + 1] = uint8_t((v >> 8) & 0xFF);
              body_off += 2;
            }
          }
        }
      } else {
        for (uint32_t nb = 0; nb < cur_nb; nb++) {
          uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
          uint32_t ng_start = (global_nt_mxu * MXU_NT) / QBLK;
          for (uint32_t k = 0; k < cur_k; k++) {
            for (uint32_t ng = 0; ng < ng_per_mxu_nt; ng++) {
              uint32_t src_k = kt * TILE_DMA_KT + k;
              uint16_t v = src[src_k * ng_total + ng_start + ng];
              dst[body_off + 0] = uint8_t(v & 0xFF);
              dst[body_off + 1] = uint8_t((v >> 8) & 0xFF);
              body_off += 2;
            }
          }
        }
      }
      out_byte_off += slot_bytes;
    }
  }
}

int main(int argc, char** argv) {
  parse_args(argc, argv);
  printf("tile_scale_zp_w4a16  K=%u N=%u QBLK=%u QDIR=%u\n", K, N, QBLK, QDIR);

  uint32_t body_bytes, slot_bytes, total_bytes, nt_dma_count;
  compute_slot_layout(body_bytes, slot_bytes, total_bytes, nt_dma_count);
  printf("  body_bytes=%u  slot_bytes=%u  total_bytes=%u  nt_dma_count=%u\n",
         body_bytes, slot_bytes, total_bytes, nt_dma_count);

  // Build synthetic 2-D source [rows, cols] of uint16 values.
  uint32_t src_rows, src_cols;
  if (QDIR == 0) { src_rows = K / QBLK; src_cols = N; }
  else           { src_rows = K;        src_cols = (N + QBLK - 1) / QBLK; }
  size_t src_elems = size_t(src_rows) * src_cols;
  std::vector<uint16_t> h_src(src_elems);
  for (size_t i = 0; i < src_elems; i++) h_src[i] = uint16_t(i & 0xFFFF);

  // CPU reference.
  std::vector<uint8_t> h_ref;
  cpu_tile_scale_zp(h_src, h_ref, total_bytes, slot_bytes, body_bytes, nt_dma_count);

  // Device run.
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(uint16_t), VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, total_bytes,                  VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_elems * sizeof(uint16_t)));

  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t tpb = uint32_t(num_threads);

  uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  uint32_t cur_k   = (k_tiles == 1) ? K : TILE_DMA_KT;
  uint32_t cur_groups   = cur_k / QBLK;
  uint32_t ng_per_mxu_nt = (TILE_DMA_MXU_NT + QBLK - 1) / QBLK;
  uint32_t slot_elems = slot_bytes / 2;
  uint32_t blocks_x = (slot_elems + tpb - 1) / tpb;

  auto log2_pow2 = [](uint32_t v) -> uint32_t {
    if (v < 1) v = 1;
    uint32_t r = 0;
    while ((1u << r) < v) r++;
    return r;
  };

  kernel_arg_t karg = {};
  karg.grid_dim[0]  = blocks_x;
  karg.grid_dim[1]  = nt_dma_count;
  karg.grid_dim[2]  = k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.K            = K;
  karg.N            = N;
  karg.QBLK         = QBLK;
  karg.QDIR         = QDIR;
  karg.slot_bytes   = slot_bytes;
  karg.body_bytes   = body_bytes;
  karg.log2_cur_groups    = (QDIR == 0) ? log2_pow2(cur_groups) : 0;
  karg.log2_cur_k         = (QDIR == 1) ? log2_pow2(cur_k) : 0;
  karg.log2_ng_per_mxu_nt = (QDIR == 1) ? log2_pow2(ng_per_mxu_nt) : 0;
  karg.log2_qblk          = log2_pow2(QBLK);

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
