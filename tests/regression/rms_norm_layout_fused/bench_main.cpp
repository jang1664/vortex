// Benchmark harness for rms_norm_layout_fused.

#include "common.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = float;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h gamma_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _ret = _expr;                                                       \
    if (0 == _ret)                                                          \
      break;                                                                \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);                \
    cleanup();                                                              \
    exit(-1);                                                               \
  } while (false)

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (gamma_buffer) vx_mem_free(gamma_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void initialize_input(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    vec[i] = -1.0f + 2.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
  }
}

static void initialize_gamma(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    vec[i] = 0.5f + (float((i * 1597334677u) % 1000) / 2000.0f);
  }
}

static std::vector<data_t> build_reference(const std::vector<data_t>& input,
                                           const std::vector<data_t>& gamma,
                                           uint32_t M,
                                           uint32_t M_pad,
                                           uint32_t K,
                                           float eps) {
  std::vector<data_t> plain(size_t(M) * K, 0.0f);
  for (uint32_t m = 0; m < M; ++m) {
    double sum_sq = 0.0;
    for (uint32_t k = 0; k < K; ++k) {
      double v = input[(uint64_t)m * K + k];
      sum_sq += v * v;
    }
    float rms = 1.0f / std::sqrt(float(sum_sq / K) + eps);
    for (uint32_t k = 0; k < K; ++k) {
      plain[(uint64_t)m * K + k] = input[(uint64_t)m * K + k] * rms * gamma[k];
    }
  }

  std::vector<data_t> ref(size_t(M_pad) * K, 0.0f);
  const uint32_t k_tiles = K / TILE_DMA_KT;
  size_t idx = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    uint32_t k_mic = TILE_DMA_KT / TILE_DMA_MXU_KT;
    for (uint32_t kb = 0; kb < k_mic; ++kb) {
      for (uint32_t m = 0; m < M_pad; ++m) {
        for (uint32_t k = 0; k < TILE_DMA_MXU_KT; ++k) {
          if (m < M) {
            uint32_t gk = kt * TILE_DMA_KT + kb * TILE_DMA_MXU_KT + k;
            ref[idx] = plain[(uint64_t)m * K + gk];
          }
          ++idx;
        }
      }
    }
  }
  return ref;
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);

  uint32_t M = 4;
  uint32_t K = 4096;
  float eps = 1e-6f;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-m") == 0) M = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-eps") == 0) eps = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [-m M] [-k K] [-eps E]\n", argv[0]);
      return 0;
    }
  }

  if (K % TILE_DMA_KT != 0) {
    printf("ERROR: K must be multiple of %u (got %u)\n", TILE_DMA_KT, K);
    return 1;
  }

  uint32_t M_pad = (M + 7u) & ~7u;
  if (!bench.csv) {
    printf("RMSNorm layout fused bench: M=%u M_pad=%u K=%u eps=%e warmup=%d iterations=%d\n",
           M, M_pad, K, eps, bench.warmup, bench.iterations);
  }

  size_t input_elems = size_t(M) * K;
  size_t output_elems = size_t(M_pad) * K;
  uint32_t input_bytes = input_elems * sizeof(data_t);
  uint32_t output_bytes = output_elems * sizeof(data_t);
  uint32_t gamma_bytes = K * sizeof(data_t);

  std::vector<data_t> h_in(input_elems);
  std::vector<data_t> h_gamma(K);
  initialize_input(h_in);
  initialize_gamma(h_gamma);
  std::vector<data_t> h_ref = build_reference(h_in, h_gamma, M, M_pad, K, eps);
  std::vector<data_t> h_out(output_elems);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, gamma_bytes, VX_MEM_READ, &gamma_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(gamma_buffer, h_gamma.data(), 0, gamma_bytes));

  uint64_t num_warps = 0, num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t tpb = 1;
  while ((tpb << 1) <= threads_per_block) tpb <<= 1;

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_RMSNORM_LAYOUT_FUSED;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(gamma_buffer, &kernel_arg.gamma_addr));
  kernel_arg.M_real = M;
  kernel_arg.M_pad = M_pad;
  kernel_arg.K = K;
  kernel_arg.eps = eps;
  kernel_arg.grid_dim[0] = M;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = tpb;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, output_bytes));

  size_t errors = 0;
  float max_diff = 0.0f;
  size_t flat_idx = 0;
  const uint32_t k_tiles = K / TILE_DMA_KT;
  const uint32_t k_mic = TILE_DMA_KT / TILE_DMA_MXU_KT;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    (void)kt;
    for (uint32_t kb = 0; kb < k_mic; ++kb) {
      (void)kb;
      for (uint32_t m = 0; m < M_pad; ++m) {
        for (uint32_t k = 0; k < TILE_DMA_MXU_KT; ++k) {
          (void)k;
          if (m < M) {
            float diff = std::fabs(h_out[flat_idx] - h_ref[flat_idx]);
            max_diff = std::max(max_diff, diff);
            float thr = std::max(1e-4f, std::fabs(h_ref[flat_idx]) * 0.01f);
            if (diff > thr) ++errors;
          }
          ++flat_idx;
        }
      }
    }
  }
  if (errors != 0) {
    printf("Validation FAILED: errors=%zu max_diff=%.6f\n", errors, max_diff);
    cleanup();
    return -1;
  }

  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw; sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
  }

  stats.report("rms_norm_layout_fused", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
