// Benchmark harness for silu_layout_fused.

#include "common.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
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
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static float silu_cpu(float x) {
  return x / (1.0f + std::exp(-x));
}

static void initialize_input(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    float x = -2.0f + 4.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    vec[i] = float_to_fp16(x);
  }
}

static std::vector<data_t> build_reference(const std::vector<data_t>& input,
                                           uint32_t M,
                                           uint32_t M_pad,
                                           uint32_t K) {
  std::vector<data_t> ref(size_t(M_pad) * K, 0);
  const uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  size_t idx = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    uint32_t cur_k = (K - kt * TILE_DMA_KT < TILE_DMA_KT)
                         ? (K - kt * TILE_DMA_KT)
                         : TILE_DMA_KT;
    uint32_t k_mic = cur_k / TILE_DMA_MXU_KT;
    for (uint32_t kb = 0; kb < k_mic; ++kb) {
      for (uint32_t m = 0; m < M_pad; ++m) {
        for (uint32_t k = 0; k < TILE_DMA_MXU_KT; ++k) {
          if (m < M) {
            uint32_t gk = kt * TILE_DMA_KT + kb * TILE_DMA_MXU_KT + k;
            ref[idx] = float_to_fp16(silu_cpu(fp16_to_float(input[(uint64_t)m * K + gk])));
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
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-m") == 0) M = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [-m M] [-k K]\n", argv[0]);
      return 0;
    }
  }

  if (K % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: K must be multiple of %u\n", TILE_DMA_MXU_KT);
    return 1;
  }

  uint32_t M_pad = (M + 7u) & ~7u;
  if (!bench.csv) {
    printf("SiLU layout fused bench: M=%u M_pad=%u K=%u warmup=%d iterations=%d\n",
           M, M_pad, K, bench.warmup, bench.iterations);
  }

  size_t input_elems = size_t(M) * K;
  size_t output_elems = size_t(M_pad) * K;
  uint32_t input_bytes = input_elems * sizeof(data_t);
  uint32_t output_bytes = output_elems * sizeof(data_t);

  std::vector<data_t> h_in(input_elems);
  initialize_input(h_in);
  std::vector<data_t> h_ref = build_reference(h_in, M, M_pad, K);
  std::vector<data_t> h_out(output_elems);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(), 0, input_bytes));

  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t tpb = uint32_t(num_threads);

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_SILU_LAYOUT_FUSED;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.M_real = M;
  kernel_arg.M_pad = M_pad;
  kernel_arg.K = K;
  kernel_arg.size = input_elems;

  uint32_t k_tiles = (K + TILE_DMA_KT - 1) / TILE_DMA_KT;
  uint32_t cur_k = (k_tiles == 1) ? K : TILE_DMA_KT;
  uint32_t k_mic = cur_k / TILE_DMA_MXU_KT;
  uint32_t real_elems_per_kb = M * TILE_DMA_MXU_KT;
  kernel_arg.grid_dim[0] = (real_elems_per_kb + tpb - 1) / tpb;
  kernel_arg.grid_dim[1] = k_mic;
  kernel_arg.grid_dim[2] = k_tiles;
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
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    (void)kt;
    uint32_t cur_k_v = (K - kt * TILE_DMA_KT < TILE_DMA_KT)
                           ? (K - kt * TILE_DMA_KT)
                           : TILE_DMA_KT;
    uint32_t k_mic_v = cur_k_v / TILE_DMA_MXU_KT;
    for (uint32_t kb = 0; kb < k_mic_v; ++kb) {
      (void)kb;
      for (uint32_t m = 0; m < M_pad; ++m) {
        for (uint32_t k = 0; k < TILE_DMA_MXU_KT; ++k) {
          (void)k;
          if (m < M) {
            float got = fp16_to_float(h_out[flat_idx]);
            float expected = fp16_to_float(h_ref[flat_idx]);
            float diff = std::fabs(got - expected);
            max_diff = std::max(max_diff, diff);
            if (diff > 1e-3f) ++errors;
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

  stats.report("silu_layout_fused", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
