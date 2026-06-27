// Compare plain RMSNorm vs RMSNorm-fused-with-tile-layout kernel.
//
// Runs both kernels on the same input data and reports:
//   - Correctness of each kernel against a CPU reference
//     (plain: row-major; fused: tile-major reorder)
//   - Wall-clock latency of each kernel
//
// Usage:
//   ./rms_norm_layout_fused [-m M] [-k K] [-i iters]

#include "common.h"
#include "../vector_common/fp16.h"
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
static vx_buffer_h gamma_buf  = nullptr;
static vx_buffer_h dst_buf    = nullptr;
static vx_buffer_h mid_buf    = nullptr;  // row-major rms_norm output (for path-3)

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
  if (gamma_buf)  vx_mem_free(gamma_buf);
  if (dst_buf)    vx_mem_free(dst_buf);
  if (mid_buf)    vx_mem_free(mid_buf);
  if (args_buf)   vx_mem_free(args_buf);
  if (kernel_bin) vx_mem_free(kernel_bin);
  if (device)     vx_dev_close(device);
}

static void show_usage() {
  printf("Usage: ./rms_norm_layout_fused [-m M] [-k K] [-i iters]\n");
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
  printf("rms_norm_layout_fused  M=%u (pad=%u) K=%u iters=%u\n",
         M, M_pad, K, ITERS);

  if (K % TILE_DMA_KT != 0) {
    printf("ERROR: K must be multiple of %u (got %u)\n", TILE_DMA_KT, K);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) || !is_pow2(TILE_DMA_MXU_KT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  const float eps = 1e-6f;

  size_t in_elems     = size_t(M)     * K;
  size_t plain_out_e  = size_t(M)     * K;
  size_t tile_out_e   = size_t(M_pad) * K;
  size_t in_bytes     = in_elems    * sizeof(data_t);
  size_t plain_bytes  = plain_out_e * sizeof(data_t);
  size_t tile_bytes   = tile_out_e  * sizeof(data_t);
  size_t gamma_bytes  = size_t(K)   * sizeof(data_t);
  size_t dst_bytes    = (plain_bytes > tile_bytes) ? plain_bytes : tile_bytes;

  // Synthetic input — fp16 storage in [-1, 1].
  std::vector<data_t> h_in(in_elems);
  for (size_t i = 0; i < in_elems; i++) {
    float x = -1.0f + 2.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    h_in[i] = float_to_fp16(x);
  }
  std::vector<data_t> h_gamma(K);
  for (size_t i = 0; i < K; i++) {
    float x = 0.5f + (float((i * 1597334677u) % 1000) / 2000.0f);  // [0.5, 1.0]
    h_gamma[i] = float_to_fp16(x);
  }

  // CPU reference: rmsnorm row-major output.
  std::vector<data_t> h_ref_plain(plain_out_e, 0);
  for (uint32_t m = 0; m < M; m++) {
    double sum_sq = 0.0;
    for (uint32_t k = 0; k < K; k++) {
      double v = fp16_to_float(h_in[m * K + k]);
      sum_sq += v * v;
    }
    float rms = 1.0f / std::sqrt(float(sum_sq / K) + eps);
    for (uint32_t k = 0; k < K; k++) {
      float x = fp16_to_float(h_in[m * K + k]);
      float g = fp16_to_float(h_gamma[k]);
      h_ref_plain[m * K + k] = float_to_fp16(x * rms * g);
    }
  }

  // CPU reference: fused output (rmsnorm value in tile-major position, pad rows = 0).
  std::vector<data_t> h_ref_fused(tile_out_e, 0);
  {
    for (uint32_t m = 0; m < M; m++) {
      uint32_t mt = m / TILE_DMA_MT;
      uint32_t m0 = m % TILE_DMA_MT;
      uint32_t cm = ((M_pad - mt * TILE_DMA_MT) < TILE_DMA_MT)
                      ? (M_pad - mt * TILE_DMA_MT) : TILE_DMA_MT;
      for (uint32_t k = 0; k < K; k++) {
        uint32_t km = k / TILE_DMA_MXU_KT;
        uint32_t k0 = k % TILE_DMA_MXU_KT;
        uint64_t idx = uint64_t(mt) * TILE_DMA_MT * K
                     + uint64_t(km) * cm * TILE_DMA_MXU_KT
                     + uint64_t(m0) * TILE_DMA_MXU_KT
                     + k0;
        h_ref_fused[idx] = h_ref_plain[uint64_t(m) * K + k];
      }
    }
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &kernel_bin));
  RT_CHECK(vx_mem_alloc(device, in_bytes,    VX_MEM_READ,        &src_buf));
  RT_CHECK(vx_mem_alloc(device, gamma_bytes, VX_MEM_READ,        &gamma_buf));
  RT_CHECK(vx_mem_alloc(device, dst_bytes,   VX_MEM_WRITE,       &dst_buf));
  RT_CHECK(vx_mem_alloc(device, plain_bytes, VX_MEM_READ_WRITE,  &mid_buf));
  RT_CHECK(vx_copy_to_dev(src_buf,   h_in.data(),    0, in_bytes));
  RT_CHECK(vx_copy_to_dev(gamma_buf, h_gamma.data(), 0, gamma_bytes));

  uint64_t num_warps_dev = 0, num_threads_dev = 0;
  vx_dev_caps(device, VX_CAPS_NUM_WARPS,   &num_warps_dev);
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads_dev);
  uint32_t threads_per_block =
      (uint32_t)std::min<uint64_t>(256, num_warps_dev * num_threads_dev);
  // Round down to power of two for the tree reduction.
  uint32_t tpb = 1;
  while ((tpb << 1) <= threads_per_block) tpb <<= 1;

  uint64_t src_addr = 0, dst_addr = 0, mid_addr = 0, gamma_addr = 0;
  RT_CHECK(vx_mem_address(src_buf,   &src_addr));
  RT_CHECK(vx_mem_address(dst_buf,   &dst_addr));
  RT_CHECK(vx_mem_address(mid_buf,   &mid_addr));
  RT_CHECK(vx_mem_address(gamma_buf, &gamma_addr));

  // Common arg fields.
  kernel_arg_t karg = {};
  karg.gamma_addr = gamma_addr;
  karg.M_real = M;
  karg.M_pad  = M_pad;
  karg.K      = K;
  karg.eps    = eps;
  karg.log2_mt     = log2_u32(TILE_DMA_MT);
  karg.log2_kt     = log2_u32(TILE_DMA_KT);
  karg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);

  // ============== Plain rmsnorm (src -> mid, row-major) ==============
  karg.kernel_id    = KERNEL_RMSNORM;
  karg.input_addr   = src_addr;
  karg.output_addr  = mid_addr;
  karg.grid_dim[0]  = M;        // one block per real row
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;

  (void)launch_one(karg);  // warm-up

  double t_plain = 0.0;
  for (uint32_t i = 0; i < ITERS; i++) {
    t_plain += launch_one(karg);
  }
  double mean_plain_us = (t_plain / ITERS) * 1e6;
  printf("  [1] plain rms_norm                mean = %10.2f us\n",
         mean_plain_us);

  // Verify plain output (mid_buf).
  std::vector<data_t> h_out_plain(plain_out_e);
  RT_CHECK(vx_copy_from_dev(h_out_plain.data(), mid_buf, 0, plain_bytes));

  size_t errors_p = 0;
  double max_diff_p = 0.0;
  for (size_t i = 0; i < plain_out_e; i++) {
    float got = fp16_to_float(h_out_plain[i]);
    float expected = fp16_to_float(h_ref_plain[i]);
    float d = std::fabs(got - expected);
    float thr = std::max(1e-4f, std::fabs(expected) * 0.01f);
    if (d > thr) {
      if (errors_p < 4) {
        printf("    Mismatch[%zu]: got=%.6f ref=%.6f diff=%.6f\n",
               i, got, expected, d);
      }
      errors_p++;
    }
    if (d > max_diff_p) max_diff_p = d;
  }
  printf("      verify: max_diff=%.6e errors=%zu\n", max_diff_p, errors_p);

  // ============== Standalone tile_input_a (mid -> dst, tile-major) ==============
  karg.kernel_id   = KERNEL_TILE_INPUT_A;
  karg.input_addr  = mid_addr;
  karg.output_addr = dst_addr;
  {
    // silu_layout_fused style 3D grid: per-element thread.
    const uint32_t k_tiles = K / TILE_DMA_KT;
    const uint32_t k_mic   = TILE_DMA_KT / TILE_DMA_MXU_KT;
    const uint32_t real_elems_per_kb = M * TILE_DMA_MXU_KT;
    karg.grid_dim[0]  = (real_elems_per_kb + tpb - 1) / tpb;
    karg.grid_dim[1]  = k_mic;
    karg.grid_dim[2]  = k_tiles;
    karg.block_dim[0] = tpb;
    karg.block_dim[1] = 1;
    karg.block_dim[2] = 1;
  }
  (void)launch_one(karg);  // warm-up

  double t_tile = 0.0;
  for (uint32_t i = 0; i < ITERS; i++) {
    t_tile += launch_one(karg);
  }
  double mean_tile_us  = (t_tile / ITERS) * 1e6;
  double mean_path2_us = mean_plain_us + mean_tile_us;
  printf("  [2] plain rms_norm + tile_input_a mean = %10.2f us  (= %.2f + %.2f)\n",
         mean_path2_us, mean_plain_us, mean_tile_us);

  // Verify [2] output (tile-major in dst_buf) before fused overwrites.
  {
    std::vector<data_t> h_out_p2(tile_out_e);
    RT_CHECK(vx_copy_from_dev(h_out_p2.data(), dst_buf, 0, tile_bytes));
    size_t errors_2 = 0;
    double max_diff_2 = 0.0;
    for (uint32_t mi = 0; mi < M; mi++) {
      uint32_t mt = mi / TILE_DMA_MT;
      uint32_t m0 = mi % TILE_DMA_MT;
      uint32_t cm = ((M_pad - mt * TILE_DMA_MT) < TILE_DMA_MT)
                      ? (M_pad - mt * TILE_DMA_MT) : TILE_DMA_MT;
      for (uint32_t kk = 0; kk < K; kk++) {
        uint32_t km = kk / TILE_DMA_MXU_KT;
        uint32_t k0 = kk % TILE_DMA_MXU_KT;
        uint64_t idx = uint64_t(mt) * TILE_DMA_MT * K
                     + uint64_t(km) * cm * TILE_DMA_MXU_KT
                     + uint64_t(m0) * TILE_DMA_MXU_KT
                     + k0;
        float got = fp16_to_float(h_out_p2[idx]);
        float expected = fp16_to_float(h_ref_fused[idx]);
        float d = std::fabs(got - expected);
        float thr = std::max(1e-4f, std::fabs(expected) * 0.01f);
        if (d > thr) errors_2++;
        if (d > max_diff_2) max_diff_2 = d;
      }
    }
    printf("      verify [2]      : max_diff=%.6e errors=%zu\n",
           max_diff_2, errors_2);
  }

  // ============== Fused rms_norm + tile layout (src -> dst) ==============
  karg.kernel_id    = KERNEL_RMSNORM_LAYOUT_FUSED;
  karg.input_addr   = src_addr;
  karg.output_addr  = dst_addr;
  karg.grid_dim[0]  = M;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = tpb;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;

  (void)launch_one(karg);  // warm-up

  double t_fused = 0.0;
  for (uint32_t i = 0; i < ITERS; i++) {
    t_fused += launch_one(karg);
  }
  double mean_fused_us = (t_fused / ITERS) * 1e6;
  printf("  [3] fused rms_norm + tile         mean = %10.2f us\n",
         mean_fused_us);
  printf("\n  [3] vs [2]: %+.2f us (%+.1f%%)   -- negative = fusion is faster\n",
         mean_fused_us - mean_path2_us,
         100.0 * (mean_fused_us - mean_path2_us) / mean_path2_us);
  printf("  [3] vs [1]: %+.2f us (%+.1f%%)   -- pure overhead of adding tile work\n",
         mean_fused_us - mean_plain_us,
         100.0 * (mean_fused_us - mean_plain_us) / mean_plain_us);

  // Verify fused output (real rows only — pad rows are intentionally garbage).
  std::vector<data_t> h_out_fused(tile_out_e);
  RT_CHECK(vx_copy_from_dev(h_out_fused.data(), dst_buf, 0, tile_bytes));

  size_t errors_f = 0;
  double max_diff_f = 0.0;
  for (uint32_t m_iter = 0; m_iter < M; m_iter++) {
    uint32_t mt = m_iter / TILE_DMA_MT;
    uint32_t m0 = m_iter % TILE_DMA_MT;
    uint32_t cm = ((M_pad - mt * TILE_DMA_MT) < TILE_DMA_MT)
                    ? (M_pad - mt * TILE_DMA_MT) : TILE_DMA_MT;
    for (uint32_t kk = 0; kk < K; kk++) {
      uint32_t km = kk / TILE_DMA_MXU_KT;
      uint32_t k0 = kk % TILE_DMA_MXU_KT;
      uint64_t idx = uint64_t(mt) * TILE_DMA_MT * K
                   + uint64_t(km) * cm * TILE_DMA_MXU_KT
                   + uint64_t(m0) * TILE_DMA_MXU_KT
                   + k0;
      float got = fp16_to_float(h_out_fused[idx]);
      float expected = fp16_to_float(h_ref_fused[idx]);
      float d = std::fabs(got - expected);
      float thr = std::max(1e-4f, std::fabs(expected) * 0.01f);
      if (d > thr) {
        if (errors_f < 4) {
          printf("    Mismatch[%zu]: got=%.6f ref=%.6f diff=%.6f\n",
                 size_t(idx), got, expected, d);
        }
        errors_f++;
      }
      if (d > max_diff_f) max_diff_f = d;
    }
  }
  printf("      verify [3] fused: max_diff=%.6e errors=%zu\n",
         max_diff_f, errors_f);

  cleanup();
  return (errors_p == 0 && errors_f == 0) ? 0 : 1;
}
