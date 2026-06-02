// Minimal standalone regression test for the tile_weight_w4a16 kernel.
//
// Builds a small synthetic input [K, N/2], runs the kernel on device, copies
// the output back, and verifies byte-for-byte against the CPU reference
// (which mirrors tests/regression/fpint_gemm_ffn_hw/main.cpp::convert_weight_tiled).
//
// Usage:
//   ./tile_weight_w4a16 [-k K] [-n N]

#include "common.h"
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
  printf("Usage: ./tile_weight_w4a16 [-k K] [-n N] [-t WTRANS] [--source-transposed]\n");
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
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
}

static uint8_t get_nibble(const std::vector<uint8_t>& src, uint32_t k, uint32_t n) {
  uint8_t byte = src[(uint64_t)k * (N / 2) + (n / 2)];
  return (n & 1u) ? (byte >> 4) : (byte & 0x0f);
}

static uint8_t get_nibble_at(const std::vector<uint8_t>& src,
                             uint32_t row,
                             uint32_t col,
                             uint32_t cols) {
  uint8_t byte = src[(uint64_t)row * (cols / 2) + (col / 2)];
  return (col & 1u) ? (byte >> 4) : (byte & 0x0f);
}

// CPU reference reorder, matches convert_weight_tiled in
// tests/regression/fpint_gemm_ffn_hw/main.cpp.
static void cpu_tile_weight(const std::vector<uint8_t>& src,
                             std::vector<uint8_t>& dst) {
  const uint32_t DMA_KT      = TILE_DMA_KT;
  const uint32_t DMA_MXU_KT  = TILE_DMA_MXU_KT;
  const uint32_t DMA_MXU_NT  = TILE_DMA_MXU_NT;
  const uint32_t PAIR_PER_SUB = DMA_MXU_NT / 2;
  const uint32_t n_tiles     = N / DMA_MXU_NT;
  const uint32_t k_tiles     = (K + DMA_KT - 1) / DMA_KT;
  const uint32_t row_bytes   = N / 2;

  dst.assign(K * row_bytes, 0);
  if (SOURCE_TRANSPOSED) {
    const uint32_t logical_K = N;
    const uint32_t logical_N = K;
    const uint32_t logical_n_tiles = logical_N / DMA_MXU_NT;
    const uint32_t logical_k_tiles = (logical_K + DMA_KT - 1) / DMA_KT;

    size_t idx = 0;
    for (uint32_t kt = 0; kt < logical_k_tiles; kt++) {
      uint32_t cur_k = (logical_K - kt * DMA_KT < DMA_KT) ? (logical_K - kt * DMA_KT) : DMA_KT;
      uint32_t cur_kb = cur_k / DMA_MXU_KT;
      for (uint32_t nt = 0; nt < logical_n_tiles; nt++) {
        for (uint32_t kb = 0; kb < cur_kb; kb++) {
          for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
            uint32_t source_row = nt * DMA_MXU_NT + n;
            for (uint32_t k = 0; k < DMA_MXU_KT; k += 2) {
              uint32_t source_col0 = kt * DMA_KT + kb * DMA_MXU_KT + k;
              uint32_t source_col1 = source_col0 + 1;
              uint8_t w0 = get_nibble_at(src, source_row, source_col0, N);
              uint8_t w1 = get_nibble_at(src, source_row, source_col1, N);
              dst[idx++] = (w0 & 0x0f) | uint8_t((w1 & 0x0f) << 4);
            }
          }
        }
      }
    }
    return;
  }

  size_t idx = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t cur_k = (K - kt * DMA_KT < DMA_KT) ? (K - kt * DMA_KT) : DMA_KT;
    uint32_t cur_kb = cur_k / DMA_MXU_KT;
    for (uint32_t nt = 0; nt < n_tiles; nt++) {
      for (uint32_t kb = 0; kb < cur_kb; kb++) {
        if (WTRANS == 0) {
          for (uint32_t k = 0; k < DMA_MXU_KT; k++) {
            uint32_t gk = kt * DMA_KT + kb * DMA_MXU_KT + k;
            for (uint32_t pair = 0; pair < PAIR_PER_SUB; pair++) {
              uint32_t gn_byte = nt * PAIR_PER_SUB + pair;
              dst[idx++] = src[(uint64_t)gk * row_bytes + gn_byte];
            }
          }
        } else {
          for (uint32_t n = 0; n < DMA_MXU_NT; n++) {
            uint32_t gn = nt * DMA_MXU_NT + n;
            for (uint32_t k = 0; k < DMA_MXU_KT; k += 2) {
              uint32_t gk0 = kt * DMA_KT + kb * DMA_MXU_KT + k;
              uint32_t gk1 = gk0 + 1;
              uint8_t w0 = get_nibble(src, gk0, gn);
              uint8_t w1 = get_nibble(src, gk1, gn);
              dst[idx++] = (w0 & 0x0f) | uint8_t((w1 & 0x0f) << 4);
            }
          }
        }
      }
    }
  }
}

int main(int argc, char** argv) {
  parse_args(argc, argv);
  printf("tile_weight_w4a16 standalone test  K=%u  N=%u WTRANS=%u source_transposed=%u\n",
         K, N, WTRANS, SOURCE_TRANSPOSED);

  if (K % TILE_DMA_MXU_KT != 0 || N % TILE_DMA_MXU_NT != 0 || (N & 1)) {
    printf("ERROR: K must be multiple of %u, N must be multiple of %u (and even).\n",
           TILE_DMA_MXU_KT, TILE_DMA_MXU_NT);
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

  const size_t total_bytes = size_t(K) * (N / 2);

  // Synthetic input bytes (deterministic).
  std::vector<uint8_t> h_src(total_bytes);
  for (size_t i = 0; i < total_bytes; i++) {
    h_src[i] = uint8_t(i & 0xFF);
  }

  // CPU reference.
  std::vector<uint8_t> h_ref;
  cpu_tile_weight(h_src, h_ref);

  // Device setup.
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));

  RT_CHECK(vx_mem_alloc(device, total_bytes, VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, total_bytes, VX_MEM_WRITE, &dst_buf));

  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, total_bytes));

  kernel_arg_t karg = {};
  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t threads_per_block = uint32_t(num_threads);

  // 3D grid: chunks_per_(kt,nt) blocks × n_tiles × k_tiles
  const uint32_t logical_K = SOURCE_TRANSPOSED ? N : K;
  const uint32_t logical_N = SOURCE_TRANSPOSED ? K : N;
  uint32_t k_tiles = (logical_K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  uint32_t max_cur_k = (logical_K < TILE_DMA_KT) ? logical_K : TILE_DMA_KT;
  uint32_t cur_kb  = max_cur_k / TILE_DMA_MXU_KT;
  uint32_t n_tiles = logical_N / TILE_DMA_MXU_NT;
  uint32_t chunks_per_nt_kt = (WTRANS == 0)
                                ? (cur_kb * TILE_DMA_MXU_KT)
                                : (cur_kb * TILE_DMA_MXU_NT * (TILE_DMA_MXU_KT / 2));

  karg.grid_dim[0]  = (chunks_per_nt_kt + threads_per_block - 1) / threads_per_block;
  karg.grid_dim[1]  = n_tiles;
  karg.grid_dim[2]  = k_tiles;
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

  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args_buf));
  RT_CHECK(vx_start(device, kernel_bin, args_buf));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  std::vector<uint8_t> h_dst(total_bytes);
  RT_CHECK(vx_copy_from_dev(h_dst.data(), dst_buf, 0, total_bytes));

  // Compare.
  size_t errors = 0;
  for (size_t i = 0; i < total_bytes; i++) {
    if (h_dst[i] != h_ref[i]) {
      if (errors < 8) {
        printf("Mismatch at byte %zu:  got=0x%02x  ref=0x%02x\n",
               i, unsigned(h_dst[i]), unsigned(h_ref[i]));
      }
      errors++;
    }
  }
  cleanup();
  if (errors == 0) {
    printf("PASSED (%zu bytes match)\n", total_bytes);
    return 0;
  } else {
    printf("FAILED (%zu / %zu bytes mismatch)\n", errors, total_bytes);
    return 1;
  }
}
