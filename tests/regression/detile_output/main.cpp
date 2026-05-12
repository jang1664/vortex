// Standalone regression test for detile_output kernel.

#include "common.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t M = 4;
static uint32_t N = 64;

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

static void show_usage() { printf("Usage: ./detile_output [-m M] [-n N]\n"); }

static void parse_args(int argc, char** argv) {
  int c;
  while ((c = getopt(argc, argv, "m:n:h")) != -1) {
    switch (c) {
      case 'm': M = atoi(optarg); break;
      case 'n': N = atoi(optarg); break;
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
}

// CPU reference: given nt-major src [M_pad, N], produce row-major dst [M, N].
static void cpu_detile_output(const std::vector<uint16_t>& h_src,
                              std::vector<uint8_t>& h_dst,
                              uint32_t M, uint32_t M_pad, uint32_t N) {
  size_t out_bytes = size_t(M) * N * TILE_ELEM_BYTES;
  h_dst.assign(out_bytes, 0);
  const uint32_t MXU_NT = TILE_DMA_MXU_NT;
  for (uint32_t m = 0; m < M; m++) {
    for (uint32_t n = 0; n < N; n++) {
      uint32_t nt = n / MXU_NT;
      uint32_t n_in_sub = n - nt * MXU_NT;
      uint32_t src_elem = nt * (M_pad * MXU_NT) + m * MXU_NT + n_in_sub;
      uint16_t v = h_src[src_elem];
      uint32_t off = (m * N + n) * 2;
      h_dst[off + 0] = uint8_t(v & 0xFF);
      h_dst[off + 1] = uint8_t((v >> 8) & 0xFF);
    }
  }
}

int main(int argc, char** argv) {
  parse_args(argc, argv);
  uint32_t M_pad = (M + 7u) & ~7u;
  printf("detile_output  M=%u (pad=%u) N=%u\n", M, M_pad, N);

  if (N % TILE_DMA_MXU_NT != 0) {
    printf("ERROR: N must be multiple of %u\n", TILE_DMA_MXU_NT);
    return 1;
  }

  // Synthetic nt-major source: fill with deterministic uint16.
  size_t src_elems = size_t(M_pad) * N;
  std::vector<uint16_t> h_src(src_elems);
  for (size_t i = 0; i < src_elems; i++) h_src[i] = uint16_t((i + 1) & 0xFFFF);

  std::vector<uint8_t> h_ref;
  cpu_detile_output(h_src, h_ref, M, M_pad, N);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  size_t src_bytes = src_elems * 2;
  size_t dst_bytes = h_ref.size();
  RT_CHECK(vx_mem_alloc(device, src_bytes, VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, dst_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_src.data(), 0, src_bytes));

  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t tpb = uint32_t(num_threads);

  uint32_t n_tiles = N / TILE_DMA_MXU_NT;
  uint32_t blocks_x = (TILE_DMA_MXU_NT + tpb - 1) / tpb;

  kernel_arg_t karg = {};
  karg.grid_dim[0]  = blocks_x;
  karg.grid_dim[1]  = M;
  karg.grid_dim[2]  = n_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buf, &karg.src_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.dst_addr));
  karg.M     = M;
  karg.M_pad = M_pad;
  karg.N     = N;

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
  } else {
    printf("FAILED (%zu / %zu bytes mismatch)\n", errors, dst_bytes);
    return 1;
  }
}
