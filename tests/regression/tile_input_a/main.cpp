// Standalone regression test for tile_input_a kernel.

#include "common.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t M = 4;
static uint32_t K = 64;

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
  printf("Usage: ./tile_input_a [-m M] [-k K]\n");
}

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static void parse_args(int argc, char** argv) {
  int c;
  while ((c = getopt(argc, argv, "m:k:h")) != -1) {
    switch (c) {
      case 'm': M = atoi(optarg); break;
      case 'k': K = atoi(optarg); break;
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
}

// CPU reference (pad + reorder).
static void cpu_tile_input_a(const std::vector<uint16_t>& h_src,
                             std::vector<uint8_t>& h_dst,
                             uint32_t M_real, uint32_t M_pad, uint32_t K) {
  size_t total_bytes = size_t(M_pad) * K * TILE_ELEM_BYTES;
  h_dst.assign(total_bytes, 0);
  for (uint32_t m = 0; m < M_real; m++) {
    uint32_t mt = m / TILE_DMA_MT;
    uint32_t m0 = m % TILE_DMA_MT;
    uint32_t cm = ((M_pad - mt * TILE_DMA_MT) < TILE_DMA_MT)
                    ? (M_pad - mt * TILE_DMA_MT) : TILE_DMA_MT;
    for (uint32_t k = 0; k < K; k++) {
      uint32_t km = k / TILE_DMA_MXU_KT;
      uint32_t k0 = k % TILE_DMA_MXU_KT;
      uint64_t elem_off = uint64_t(mt) * TILE_DMA_MT * K
                        + uint64_t(km) * cm * TILE_DMA_MXU_KT
                        + uint64_t(m0) * TILE_DMA_MXU_KT
                        + k0;
      uint16_t v = h_src[uint64_t(m) * K + k];
      uint64_t off = elem_off * TILE_ELEM_BYTES;
      h_dst[off + 0] = uint8_t(v & 0xFF);
      h_dst[off + 1] = uint8_t((v >> 8) & 0xFF);
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
  parse_args(argc, argv);
  uint32_t M_pad = (M + 7u) & ~7u;
  printf("tile_input_a  M=%u (pad=%u) K=%u\n", M, M_pad, K);

  if (K % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: K must be multiple of %u\n", TILE_DMA_MXU_KT);
    return 1;
  }
  if (!validate_tile_params()) return 1;

  std::vector<uint16_t> h_src(size_t(M) * K);
  for (size_t i = 0; i < h_src.size(); i++) h_src[i] = uint16_t((i + 1) & 0xFFFF);

  std::vector<uint8_t> h_ref;
  cpu_tile_input_a(h_src, h_ref, M, M_pad, K);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  size_t src_bytes = h_src.size() * 2;
  size_t dst_bytes = h_ref.size();
  RT_CHECK(vx_mem_alloc(device, src_bytes, VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, dst_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_bytes));

  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t tpb = uint32_t(num_threads);

  uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  uint32_t k_mic   = TILE_DMA_KT / TILE_DMA_MXU_KT;
  // 4B chunk per thread (2 fp16) — mirrors silu_layout_fused store pattern.
  uint32_t CHUNKS_PER_ROW = TILE_DMA_MXU_KT / 2;   // 16
  uint32_t chunks_per_kb = M_pad * CHUNKS_PER_ROW;
  uint32_t blocks_x = (chunks_per_kb + tpb - 1) / tpb;

  kernel_arg_t karg = {};
  karg.grid_dim[0]  = blocks_x;
  karg.grid_dim[1]  = k_mic;
  karg.grid_dim[2]  = k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.M_real = M;
  karg.M_pad  = M_pad;
  karg.K      = K;
  karg.log2_mt     = log2_u32(TILE_DMA_MT);
  karg.log2_kt     = log2_u32(TILE_DMA_KT);
  karg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);

  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));
  RT_CHECK(vx_start(device, kernel_bin, args_buf));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  std::vector<uint8_t> h_dst(dst_bytes);
  RT_CHECK(vx_copy_from_dev(h_dst.data(), dst_buf, 0, dst_bytes));

  size_t errors = 0;
  for (size_t i = 0; i < dst_bytes; i++) {
    if (h_dst[i] != h_ref[i]) {
      if (errors < 8)
        printf("Mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
               i, unsigned(h_dst[i]), unsigned(h_ref[i]));
      errors++;
    }
  }
  cleanup();
  if (errors == 0) {
    printf("PASSED (%zu bytes match)\n", dst_bytes);
    return 0;
  }
  printf("FAILED (%zu / %zu bytes mismatch)\n", errors, dst_bytes);
  return 1;
}
