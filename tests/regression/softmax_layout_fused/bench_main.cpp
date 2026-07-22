#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"
#include <vortex.h>
#include <algorithm>
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

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint32_t align_up(uint32_t a, uint32_t b) {
  return ((a + b - 1) / b) * b;
}

static void init_scores(std::vector<data_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 22695477u + 1u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 64.0f);
  }
}

static size_t row_index(uint32_t b, uint32_t h, uint32_t q, uint32_t k,
                        uint32_t heads, uint32_t seq_q, uint32_t seq_k) {
  return (((size_t)b * heads + h) * seq_q + q) * seq_k + k;
}

static void pack_scores(const std::vector<data_t>& row,
                        std::vector<data_t>& tiled,
                        uint32_t batch,
                        uint32_t heads,
                        uint32_t seq_q,
                        uint32_t seq_k,
                        uint32_t seq_k_pad,
                        uint32_t M_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint64_t matrix_elems = (uint64_t)M_pad * seq_k_pad;
  std::fill(tiled.begin(), tiled.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t h = 0; h < heads; ++h) {
      const uint64_t base = batched_matrix_base(b * heads + h, matrix_elems);
      for (uint32_t q = 0; q < seq_q; ++q) {
        for (uint32_t k = 0; k < seq_k; ++k) {
          tiled[base + gemm_c_tiled_elem_offset(q, k, M_pad, seq_k_pad, log2_mt, log2_mxu_nt)] =
              row[row_index(b, h, q, k, heads, seq_q, seq_k)];
        }
      }
    }
  }
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }
  uint32_t batch = 1;
  uint32_t heads = 1;
  uint32_t seq_q = 128;
  uint32_t seq_k = 128;
  uint32_t seq_k_stride = 0;
  uint32_t use_mask = 1;
  float scale = 1.0f;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqq") == 0) seq_q = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqk") == 0) seq_k = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqk-stride") == 0) seq_k_stride = atoi(argv[++i]);
    else if (strcmp(argv[i], "-mask") == 0) use_mask = atoi(argv[++i]);
    else if (strcmp(argv[i], "-scale") == 0) scale = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] [--power-measure-latency[=on|off]] [-batch B] [-heads H] "
             "[-seqq Q] [-seqk K] [-seqk-stride KS] [-mask 0|1] [-scale S]\n",
             argv[0]);
      return 0;
    }
  }

  if (seq_k_stride == 0) {
    seq_k_stride = seq_k;
  }
  if (seq_k_stride < seq_k) {
    printf("ERROR: seqk-stride (%u) must be >= seqk (%u)\n",
           seq_k_stride, seq_k);
    return 1;
  }

  const uint32_t M_pad = (seq_q + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t seq_k_pad = align_up(
      seq_k_stride, std::max(TILE_DMA_MXU_KT, TILE_DMA_MXU_NT));
  const size_t row_elems = (size_t)batch * heads * seq_q * seq_k;
  const size_t tiled_elems = (size_t)batch * heads * M_pad * seq_k_pad;
  const size_t tiled_bytes = tiled_elems * sizeof(data_t);
  std::vector<data_t> h_input_row(row_elems);
  std::vector<data_t> h_input_tiled(tiled_elems);
  init_scores(h_input_row);
  pack_scores(h_input_row, h_input_tiled, batch, heads, seq_q, seq_k, seq_k_pad, M_pad);

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input_tiled.data(), 0, tiled_bytes));

  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
#if SOFTMAX_LAYOUT_FUSED_VARIANT == SOFTMAX_LAYOUT_FUSED_VARIANT_OPT_WARP || \
    SOFTMAX_LAYOUT_FUSED_VARIANT == SOFTMAX_LAYOUT_FUSED_VARIANT_REV2 || \
    SOFTMAX_LAYOUT_FUSED_VARIANT == SOFTMAX_LAYOUT_FUSED_VARIANT_REV2_ADDRGEN
  const uint32_t tpb = std::min(256u, (uint32_t)num_threads);
#else
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
#endif

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_SOFTMAX_LAYOUT_FUSED;
  arg.grid_dim[0] = batch * heads * seq_q;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.batch_size = batch;
  arg.num_heads = heads;
  arg.seq_len_q = seq_q;
  arg.seq_len_k = seq_k;
  arg.seq_len_k_pad = seq_k_pad;
  arg.output_k_pad = seq_k_pad;
  arg.M_pad = M_pad;
  arg.use_mask = use_mask;
  arg.scale = scale;
  arg.log2_mt = log2_u32(TILE_DMA_MT);
  arg.log2_kt = log2_u32(TILE_DMA_KT);
  arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  arg.power_kernel_iterations = 1;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  vx_bench::Stats stats;
  double first_latency_us = 0.0;
  vx_bench::IterationPerf first_iter_perf;
  if (!latency_power.begin_latency_window()) {
    cleanup();
    return -1;
  }
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    const double elapsed_us = sw.stop_us();
    if (i == 0)
      first_latency_us = elapsed_us;
    stats.record(elapsed_us);
    const vx_bench::IterationPerf iter_perf =
        vx_bench::dump_iteration_perf(device, bench, i);
    if (i == 0)
      first_iter_perf = iter_perf;
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  if (!latency_power.finish(stats.summary(), first_iter_perf)) {
    cleanup();
    return -1;
  }

  stats.report("softmax_layout_fused", bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          "softmax_layout_fused")) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          "softmax_layout_fused", bench, device, krnl_buffer, args_buffer, bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
