// Compare plain SiLU vs SiLU-fused-with-tile-layout kernel.
//
// Runs both kernels on the same input data and reports:
//   - Correctness of the fused-layout output against a CPU reference
//     (which keeps SiLU(x) in GEMM-C tiled layout)
//   - Wall-clock latency of each kernel
//
// Usage:
//   ./silu_layout_fused [-m M] [-k K] [-i iters]

#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vortex.h>
#include <unistd.h>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <algorithm>
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

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint64_t gemm_c_tiled_index(uint32_t m, uint32_t k,
                                   uint32_t M_pad, uint32_t K) {
  return gemm_c_tiled_elem_offset(
      m, k, M_pad, K, log2_u32(TILE_DMA_MT), log2_u32(TILE_DMA_MXU_NT));
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

using data_t = fp16_t;

int main(int argc, char** argv) {
  parse_args(argc, argv);

  uint32_t M_pad = (M + 7u) & ~7u;
#if SILU_LAYOUT_FUSED_VARIANT_TAG == 2
  const char* variant = "linear_skip_pad_rows";
#elif SILU_LAYOUT_FUSED_VARIANT_TAG == 1
  const char* variant = "linear_tiled";
#else
  const char* variant = "baseline";
#endif
  printf("silu_layout_fused  variant=%s M=%u (pad=%u) K=%u iters=%u\n",
         variant, M, M_pad, K, ITERS);

  if (K % TILE_DMA_MXU_NT != 0) {
    printf("ERROR: K must be multiple of %u\n", TILE_DMA_MXU_NT);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) ||
      !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  size_t in_elems  = size_t(M)     * K;
  size_t out_elems = size_t(M_pad) * K;
  size_t in_bytes  = in_elems  * sizeof(data_t);
  size_t out_bytes = out_elems * sizeof(data_t);

  // Synthetic input — random-ish fp16 in [-2, 2].
  std::vector<data_t> h_in(in_elems);
  for (size_t i = 0; i < in_elems; i++) {
    float x = -2.0f + 4.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    h_in[i] = float_to_fp16(x);
  }

  std::vector<data_t> h_in_tiled(out_elems, 0);
  for (uint32_t m = 0; m < M; ++m) {
    for (uint32_t k = 0; k < K; ++k) {
      h_in_tiled[gemm_c_tiled_index(m, k, M_pad, K)] = h_in[(uint64_t)m * K + k];
    }
  }

  // CPU reference for FUSED output (SiLU values written in GEMM-C tiled positions).
  std::vector<data_t> h_ref(out_elems, 0);
  {
    for (uint32_t m = 0; m < M; m++) {
      for (uint32_t k = 0; k < K; k++) {
        uint64_t out_idx = gemm_c_tiled_index(m, k, M_pad, K);
        float x = fp16_to_float(h_in[uint64_t(m) * K + k]);
        h_ref[out_idx] = float_to_fp16(x / (1.0f + std::exp(-x)));
      }
    }
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, out_bytes, VX_MEM_READ,  &src_buf));
  RT_CHECK(vx_mem_alloc(device, out_bytes, VX_MEM_WRITE, &dst_buf));
  RT_CHECK(vx_copy_to_dev(src_buf, h_in.data(), 0, in_bytes));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores);
  vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps);
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);
  uint32_t tpb = std::min(256u, uint32_t(num_warps * num_threads));
  uint32_t max_blocks = std::max(1u, uint32_t(num_cores) * 4u);

  // Common arg fields.
  kernel_arg_t karg = {};
  RT_CHECK(vx_mem_address(src_buf, &karg.input_addr));
  RT_CHECK(vx_mem_address(dst_buf, &karg.output_addr));
  karg.M_real = M;
  karg.M_pad  = M_pad;
  karg.K      = K;
  karg.size   = in_elems;       // plain silu: M*K elements only
  karg.log2_mt     = log2_u32(TILE_DMA_MT);
  karg.log2_kt     = log2_u32(TILE_DMA_KT);
  karg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);

  // -------------- Plain silu --------------
  karg.kernel_id    = KERNEL_SILU;
  karg.grid_dim[0]  = std::min(uint32_t((in_elems + tpb - 1) / tpb), max_blocks);
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

  // -------------- Fused silu on GEMM-C tiled input/output (real rows only) --------------
  // Launch a capped 1D grid over real 32-element N chunks. Pad rows are left
  // uninitialized because downstream GEMM output for those rows is discarded.
  RT_CHECK(vx_copy_to_dev(src_buf, h_in_tiled.data(), 0, out_bytes));
  uint32_t total_chunks = M * (K / TILE_DMA_MXU_NT);

  karg.kernel_id    = KERNEL_SILU_LAYOUT_FUSED;
  karg.grid_dim[0]  = std::min((total_chunks + tpb - 1) / tpb, max_blocks);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
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
  std::vector<data_t> h_out(out_elems);
  RT_CHECK(vx_copy_from_dev(h_out.data(), dst_buf, 0, out_bytes));

  const float TOL = 1e-3f;
  size_t errors = 0;
  double max_diff = 0.0;
  for (uint32_t m_iter = 0; m_iter < M; m_iter++) {
    for (uint32_t kk = 0; kk < K; kk++) {
      uint64_t idx = gemm_c_tiled_index(m_iter, kk, M_pad, K);
      float got = fp16_to_float(h_out[idx]);
      float expected = fp16_to_float(h_ref[idx]);
      float d = std::fabs(got - expected);
      if (d > TOL) {
        if (errors < 4) {
          printf("  Mismatch[%zu]: got=%.6f ref=%.6f\n",
                 size_t(idx), got, expected);
        }
        errors++;
      }
      if (d > max_diff) max_diff = d;
    }
  }
  cleanup();
  printf("  fused output (real rows only): max_diff=%.6e, errors=%zu (tol=%.0e)\n",
         max_diff, errors, TOL);
  return (errors == 0) ? 0 : 1;
}
