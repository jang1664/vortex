// Benchmark harness for silu_layout_fused.

#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
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

enum class Variant {
  RowMatched,
  LayoutFused,
};

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

static void initialize_input(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    float x = -2.0f + 4.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    vec[i] = float_to_fp16(x);
  }
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

static const char* variant_label(Variant variant) {
  return (variant == Variant::RowMatched)
      ? "silu_row_matched"
      : "silu_layout_fused";
}

static uint32_t variant_kernel_id(Variant variant) {
  return (variant == Variant::RowMatched)
      ? KERNEL_SILU_ROW_MATCHED
      : KERNEL_SILU_LAYOUT_FUSED;
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);

  uint32_t M = 4;
  uint32_t K = 4096;
  Variant variant = Variant::LayoutFused;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-m") == 0) M = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "--variant") == 0 && i + 1 < argc) {
      const char* value = argv[++i];
      if (strcmp(value, "row") == 0 || strcmp(value, "row-matched") == 0) {
        variant = Variant::RowMatched;
      } else if (strcmp(value, "layout") == 0 || strcmp(value, "layout-fused") == 0) {
        variant = Variant::LayoutFused;
      } else {
        printf("ERROR: --variant must be row or layout\n");
        return 1;
      }
    } else if (strncmp(argv[i], "--variant=", 10) == 0) {
      const char* value = argv[i] + 10;
      if (strcmp(value, "row") == 0 || strcmp(value, "row-matched") == 0) {
        variant = Variant::RowMatched;
      } else if (strcmp(value, "layout") == 0 || strcmp(value, "layout-fused") == 0) {
        variant = Variant::LayoutFused;
      } else {
        printf("ERROR: --variant must be row or layout\n");
        return 1;
      }
    }
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--variant=row|layout] "
             "[-m M] [-k K]\n", argv[0]);
      return 0;
    }
  }

  if (K % TILE_DMA_MXU_NT != 0) {
    printf("ERROR: K must be multiple of %u\n", TILE_DMA_MXU_NT);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) ||
      !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  uint32_t M_pad = (M + 7u) & ~7u;
  if (!bench.csv) {
    printf("SiLU layout fused bench: variant=%s M=%u M_pad=%u K=%u warmup=%d iterations=%d\n",
           variant_label(variant), M, M_pad, K, bench.warmup, bench.iterations);
  }

  size_t input_elems = size_t(M) * K;
  size_t output_elems = size_t(M_pad) * K;
  uint32_t output_bytes = output_elems * sizeof(data_t);

  std::vector<data_t> h_in(input_elems);
  initialize_input(h_in);
  std::vector<data_t> h_in_device(output_elems, 0);
  if (variant == Variant::RowMatched) {
    std::copy(h_in.begin(), h_in.end(), h_in_device.begin());
  } else {
    for (uint32_t m = 0; m < M; ++m) {
      for (uint32_t k = 0; k < K; ++k) {
        h_in_device[gemm_c_tiled_index(m, k, M_pad, K)] = h_in[(uint64_t)m * K + k];
      }
    }
  }
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in_device.data(), 0, output_bytes));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t tpb = std::min(256u, uint32_t(num_warps * num_threads));
  uint32_t max_blocks = std::max(1u, uint32_t(num_cores) * 4u);

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = variant_kernel_id(variant);
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.M_real = M;
  kernel_arg.M_pad = M_pad;
  kernel_arg.K = K;
  kernel_arg.size = input_elems;
  kernel_arg.log2_mt = log2_u32(TILE_DMA_MT);
  kernel_arg.log2_kt = log2_u32(TILE_DMA_KT);
  kernel_arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);

  uint32_t total_chunks = M * (K / TILE_DMA_MXU_NT);
  uint32_t blocks = (total_chunks + tpb - 1) / tpb;
  kernel_arg.grid_dim[0] = std::min(blocks, max_blocks);
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = tpb;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

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

  stats.report(variant_label(variant), bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
