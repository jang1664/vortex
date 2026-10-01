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

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;
vx_buffer_h cos_buffer = nullptr;
vx_buffer_h sin_buffer = nullptr;

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
  if (cos_buffer) vx_mem_free(cos_buffer);
  if (sin_buffer) vx_mem_free(sin_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint32_t parse_layout_to(const char* value) {
  if (strcmp(value, "gemm_a_tiled") == 0 || strcmp(value, "a") == 0) {
    return ROPE_LAYOUT_TO_GEMM_A;
  }
  if (strcmp(value, "gemm_w_tiled") == 0 || strcmp(value, "w") == 0) {
    return ROPE_LAYOUT_TO_GEMM_W;
  }
  if (strcmp(value, "row_major") == 0 || strcmp(value, "row") == 0) {
    return ROPE_LAYOUT_TO_ROW_MAJOR;
  }
  if (strcmp(value, "head_major_row") == 0 || strcmp(value, "bhsd") == 0) {
    return ROPE_LAYOUT_TO_HEAD_MAJOR_ROW;
  }
  printf("ERROR: --layout-to must be gemm_a_tiled, gemm_w_tiled, row_major, or head_major_row\n");
  exit(1);
}

static const char* benchmark_name(uint32_t layout_to) {
  if (layout_to == ROPE_LAYOUT_TO_GEMM_A) return "rope_layout_fused_a";
  if (layout_to == ROPE_LAYOUT_TO_GEMM_W) return "rope_layout_fused_w";
  if (layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW) return "rope_layout_fused_head_major_row";
  return "rope_layout_fused_row";
}

static size_t row_index(uint32_t b, uint32_t s, uint32_t h, uint32_t d,
                        uint32_t seq, uint32_t heads, uint32_t head_dim) {
  return (((size_t)b * seq + s) * heads + h) * head_dim + d;
}

static void init_input(std::vector<data_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 80.0f);
  }
}

static void precompute_freqs(std::vector<data_t>& cos_table,
                             std::vector<data_t>& sin_table,
                             uint32_t max_seq_len,
                             uint32_t head_dim) {
  const uint32_t half_dim = head_dim >> 1;
  cos_table.resize((size_t)max_seq_len * half_dim);
  sin_table.resize((size_t)max_seq_len * half_dim);
  for (uint32_t pos = 0; pos < max_seq_len; ++pos) {
    for (uint32_t p = 0; p < half_dim; ++p) {
      float freq = std::pow(10000.0f, -2.0f * float(p) / float(head_dim));
      float theta = float(pos) * freq;
      cos_table[(size_t)pos * half_dim + p] = float_to_fp16(std::cos(theta));
      sin_table[(size_t)pos * half_dim + p] = float_to_fp16(std::sin(theta));
    }
  }
}

static void pack_projection(const std::vector<data_t>& row,
                            std::vector<data_t>& tiled,
                            uint32_t batch,
                            uint32_t seq,
                            uint32_t heads,
                            uint32_t head_dim,
                            uint32_t input_m_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint32_t input_n = heads * head_dim;
  std::fill(tiled.begin(), tiled.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      const uint32_t m = b * seq + s;
      for (uint32_t h = 0; h < heads; ++h) {
        for (uint32_t d = 0; d < head_dim; ++d) {
          const uint32_t n = h * head_dim + d;
          tiled[gemm_c_tiled_elem_offset(m, n, input_m_pad, input_n, log2_mt, log2_mxu_nt)] =
              row[row_index(b, s, h, d, seq, heads, head_dim)];
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
  uint32_t seq = 128;
  uint32_t heads = 32;
  uint32_t head_dim = 128;
  uint32_t max_seq = 4096;
  uint32_t pos_offset = 0;
  uint32_t layout_to = ROPE_LAYOUT_TO_GEMM_A;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0) seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-headdim") == 0) head_dim = atoi(argv[++i]);
    else if (strcmp(argv[i], "-maxseq") == 0) max_seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-offset") == 0) pos_offset = atoi(argv[++i]);
    else if (strcmp(argv[i], "--layout-to") == 0) layout_to = parse_layout_to(argv[++i]);
    else if (strncmp(argv[i], "--layout-to=", 12) == 0) layout_to = parse_layout_to(argv[i] + 12);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] [--output=PATH] "
             "[--output-append] [--power-measure-latency[=on|off]] [-batch B] [-seq S] [-heads H] [-headdim D] "
             "[-maxseq N] [-offset O] [--layout-to gemm_a_tiled|gemm_w_tiled|row_major|head_major_row]\n", argv[0]);
      return 0;
    }
  }

  const uint32_t input_m = batch * seq;
  const uint32_t input_m_pad = (input_m + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t output_m_pad = (seq + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t input_n = heads * head_dim;
  const size_t input_row_elems = (size_t)batch * seq * heads * head_dim;
  const size_t input_tiled_elems = (size_t)input_m_pad * input_n;
  const size_t output_elems = (layout_to == ROPE_LAYOUT_TO_GEMM_A)
      ? (size_t)batch * heads * output_m_pad * head_dim
      : (layout_to == ROPE_LAYOUT_TO_GEMM_W)
          ? (size_t)batch * heads * head_dim * max_seq
          : input_row_elems;
  const size_t input_tiled_bytes = input_tiled_elems * sizeof(data_t);
  const size_t output_bytes = output_elems * sizeof(data_t);

  const size_t freq_elems = (size_t)max_seq * (head_dim >> 1);
  std::vector<data_t> h_input_tiled, h_cos, h_sin;
  if (bench.copy_inputs) {
    std::vector<data_t> h_input_row(input_row_elems);
    h_input_tiled.resize(input_tiled_elems);
    init_input(h_input_row);
    precompute_freqs(h_cos, h_sin, max_seq, head_dim);
    pack_projection(h_input_row, h_input_tiled, batch, seq, heads, head_dim, input_m_pad);
  }

  vx_bench::LatencyPowerMeasurement latency_power(bench);
  if (!latency_power.prestart()) {
    return -1;
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_tiled_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_elems * sizeof(data_t), VX_MEM_READ, &cos_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_elems * sizeof(data_t), VX_MEM_READ, &sin_buffer));
  if (bench.copy_inputs) {
    RT_CHECK(vx_copy_to_dev(input_buffer, h_input_tiled.data(), 0, input_tiled_bytes));
    RT_CHECK(vx_copy_to_dev(cos_buffer, h_cos.data(), 0, freq_elems * sizeof(data_t)));
    RT_CHECK(vx_copy_to_dev(sin_buffer, h_sin.data(), 0, freq_elems * sizeof(data_t)));
  }

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t total_pairs = batch * seq * heads * (head_dim >> 1);
  const uint32_t blocks = std::min(
      (total_pairs + tpb - 1u) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_ROPE_LAYOUT_FUSED;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  RT_CHECK(vx_mem_address(cos_buffer, &arg.cos_addr));
  RT_CHECK(vx_mem_address(sin_buffer, &arg.sin_addr));
  arg.batch_size = batch;
  arg.seq_len = seq;
  arg.num_heads = heads;
  arg.head_dim = head_dim;
  arg.max_seq_len = max_seq;
  arg.pos_offset = pos_offset;
  arg.layout_to = layout_to;
  arg.input_m_pad = input_m_pad;
  arg.output_m_pad = output_m_pad;
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

  stats.report(benchmark_name(layout_to), bench);

  if (!vx_bench::prepare_power_kernel_iterations(
          bench, arg, args_buffer, first_latency_us, first_iter_perf,
          benchmark_name(layout_to))) {
    cleanup();
    return -1;
  }

  if (!vx_bench::run_power_measurement(
          benchmark_name(layout_to), bench, device, krnl_buffer, args_buffer,
          bench.power_measure_latency)) {
    cleanup();
    return -1;
  }
  cleanup();
  return 0;
}
