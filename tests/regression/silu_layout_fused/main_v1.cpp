// Compare plain SiLU vs SiLU-fused-with-tile-layout kernel.
//
// Runs both kernels on the same input data and reports:
//   - Correctness of the fused-layout output against a CPU reference
//     (which mirrors tile_input_a's reorder on top of SiLU(x))
//   - Wall-clock latency of each kernel
//
// Usage:
//   ./silu_layout_fused [-m M] [-k K] [-i iters]

#include "common.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <chrono>

static uint32_t M     = 4;
static uint32_t K     = 4096;
static uint32_t ITERS = 5;

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
  printf("Usage: ./silu_layout_fused [-m M] [-k K] [-i iters]\n");
}

static void parse_args(int argc, char** argv) {
  int c;
  while ((c = getopt(argc, argv, "m:k:i:h")) != -1) {
    switch (c) {
      case 'm': M     = atoi(optarg); break;
      case 'k': K     = atoi(optarg); break;
      case 'i': ITERS = atoi(optarg); break;
      case 'h': show_usage(); exit(0);
      default:  show_usage(); exit(1);
    }
  }
}

// Time one launch (vx_start + vx_ready_wait). Returns elapsed seconds.
static double launch_one(const kernel_arg_t& karg) {
  vx_buffer_h tmp_args = nullptr;
  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &tmp_args));
  auto t0 = std::chrono::high_resolution_clock::now();
  RT_CHECK(vx_start(device, kernel_bin, tmp_args));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  auto t1 = std::chrono::high_resolution_clock::now();
  vx_mem_free(tmp_args);
  return std::chrono::duration<double>(t1 - t0).count();
}

int main(int argc, char** argv) {
  parse_args(argc, argv);

  uint32_t M_pad = (M + 7u) & ~7u;
  printf("silu_layout_fused  M=%u (pad=%u) K=%u iters=%u\n", M, M_pad, K, ITERS);

  if (K % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: K must be multiple of %u\n", TILE_DMA_MXU_KT);
    return 1;
  }

  size_t in_elems  = size_t(M)     * K;
  size_t out_elems = size_t(M_pad) * K;
  size_t in_bytes  = in_elems  * sizeof(float);
  size_t out_bytes = out_elems * sizeof(float);

  // Synthetic input — random-ish fp32 in [-2, 2].
  std::vector<float> h_in(in_elems);
  for (size_t i = 0; i < in_elems; i++) {
    h_in[i] = -2.0f + 4.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
  }

  // CPU reference for FUSED output (silu values written in tile-major positions).
  std::vector<float> h_ref(out_elems, 0.0f);
  {
    const uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
    size_t idx = 0;
    for (uint32_t kt = 0; kt < k_tiles; kt++) {
      uint32_t cur_k = (K - kt * TILE_DMA_KT < TILE_DMA_KT)
                       ? (K - kt * TILE_DMA_KT) : TILE_DMA_KT;
      uint32_t k_mic = cur_k / TILE_DMA_MXU_KT;
      for (uint32_t kb = 0; kb < k_mic; kb++) {
        for (uint32_t m = 0; m < M_pad; m++) {
          for (uint32_t k = 0; k < TILE_DMA_MXU_KT; k++) {
            float v = 0.0f;
            if (m < M) {
              uint32_t gk = kt * TILE_DMA_KT + kb * TILE_DMA_MXU_KT + k;
              float x = h_in[m * K + gk];
              v = x / (1.0f + std::exp(-x));
            }
            h_ref[idx++] = v;
          }
        }
      }
    }
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, in_bytes,  VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, out_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_in.data(), 0, in_bytes));

  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t tpb = uint32_t(num_threads);

  // Common arg fields.
  kernel_arg_t karg = {};
  RT_CHECK(vx_mem_address(src_buf, &karg.input_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.output_addr));
  karg.M_real = M;
  karg.M_pad  = M_pad;
  karg.K      = K;
  karg.size   = in_elems;       // plain silu: M*K elements only

  // -------------- Plain silu --------------
  karg.kernel_id    = KERNEL_SILU;
  karg.grid_dim[0]  = (in_elems + tpb - 1) / tpb;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;

  // Warm-up.
  (void)launch_one(karg);

  double t_silu = 0.0;
  for (uint32_t i = 0; i < ITERS; i++) {
    t_silu += launch_one(karg);
  }
  double mean_silu_us = (t_silu / ITERS) * 1e6;
  printf("  plain silu     mean = %10.2f us  (size=%zu elems)\n",
         mean_silu_us, in_elems);

  // -------------- Fused silu + tile_input_a (real rows only) --------------
  uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  uint32_t cur_k   = (k_tiles == 1) ? K : TILE_DMA_KT;
  uint32_t k_mic   = cur_k / TILE_DMA_MXU_KT;
  // Launch threads ONLY for M_real rows (pad rows left uninitialized).
  uint32_t real_elems_per_kb = M * TILE_DMA_MXU_KT;

  karg.kernel_id    = KERNEL_SILU_LAYOUT_FUSED;
  karg.grid_dim[0]  = (real_elems_per_kb + tpb - 1) / tpb;
  karg.grid_dim[1]  = k_mic;
  karg.grid_dim[2]  = k_tiles;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;

  // Warm-up.
  (void)launch_one(karg);

  double t_fused = 0.0;
  for (uint32_t i = 0; i < ITERS; i++) {
    t_fused += launch_one(karg);
  }
  double mean_fused_us = (t_fused / ITERS) * 1e6;
  printf("  fused (+tile)  mean = %10.2f us  (out elems=%zu)\n",
         mean_fused_us, out_elems);
  printf("  delta = %+.2f us (%+.1f%%)\n",
         mean_fused_us - mean_silu_us,
         100.0 * (mean_fused_us - mean_silu_us) / mean_silu_us);

  // Verify fused output correctness — REAL ROWS ONLY.
  // The kernel intentionally leaves pad-row positions uninitialized
  // (downstream GEMM doesn't care; its output for pad rows is discarded).
  std::vector<float> h_out(out_elems);
  RT_CHECK(vx_copy_from_dev(h_out.data(), dst_buf, 0, out_bytes));

  const float TOL = 1e-3f;
  size_t errors = 0;
  double max_diff = 0.0;
  const uint32_t k_tiles_v = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  size_t flat_idx = 0;
  for (uint32_t kt = 0; kt < k_tiles_v; kt++) {
    const uint32_t cur_k_v = (K - kt * TILE_DMA_KT < TILE_DMA_KT)
                             ? (K - kt * TILE_DMA_KT) : TILE_DMA_KT;
    const uint32_t k_mic_v = cur_k_v / TILE_DMA_MXU_KT;
    for (uint32_t kb = 0; kb < k_mic_v; kb++) {
      for (uint32_t m_iter = 0; m_iter < M_pad; m_iter++) {
        for (uint32_t kk = 0; kk < TILE_DMA_MXU_KT; kk++) {
          if (m_iter < M) {  // real row -> check
            float d = std::fabs(h_out[flat_idx] - h_ref[flat_idx]);
            if (d > TOL) {
              if (errors < 4) {
                printf("  Mismatch[%zu]: got=%.6f ref=%.6f\n",
                       flat_idx, h_out[flat_idx], h_ref[flat_idx]);
              }
              errors++;
            }
            if (d > max_diff) max_diff = d;
          }
          flat_idx++;
        }
      }
    }
  }
  cleanup();
  printf("  fused output (real rows only): max_diff=%.6e, errors=%zu (tol=%.0e)\n",
         max_diff, errors, TOL);
  return (errors == 0) ? 0 : 1;
}
