// Benchmark harness for softmax. Reuses the same kernel.vxbin built from
// kernel.cpp; differs from main.cpp only in that it (1) runs warmup +
// timed-iteration loops around vx_start/vx_ready_wait and (2) prints latency
// stats at the end. It intentionally does not validate output:
// functional checks belong to main.cpp, while this binary is for timing only.
//
// CLI: same shape args as main.cpp (-batch / -heads / -seqq / -seqk / -mask /
// -scale) plus --warmup=N / --iterations=N / --csv / --output=PATH /
// --output-append parsed by bench_util.

#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <assert.h>
#include <vortex.h>
#include "common.h"
#include "host_variant.h"
#include "../vector_common/fp16.h"
#include "bench_util.h"

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;
    val = float_to_fp16(x);
  }
}

static void pack_rows_to_pitch(
    std::vector<uint8_t>& dst,
    const std::vector<data_t>& src,
    uint32_t total_rows,
    uint32_t seq_len_k,
    uint32_t row_pitch_bytes) {
  uint32_t row_bytes = seq_len_k * sizeof(data_t);
  const auto* src_bytes = reinterpret_cast<const uint8_t*>(src.data());
  for (uint32_t row = 0; row < total_rows; ++row) {
    std::memcpy(dst.data() + row * row_pitch_bytes,
                src_bytes + row * row_bytes,
                row_bytes);
  }
}

int main(int argc, char *argv[]) {
  // Bench flags (--warmup / --iterations / --csv / --output / --output-append) — stripped from argv.
  auto bench = vx_bench::parse(argc, argv);
  if (vx_bench::report_parse_error(bench)) {
    return -1;
  }

  // Shape defaults match main.cpp.
  uint32_t batch_size = 2;
  uint32_t num_heads = 16;
  uint32_t seq_len_q = 8;
  uint32_t seq_len_k = 8;
  uint32_t use_mask = 1;
  float scale = 1.0f / std::sqrt(64.0f);

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0)       batch_size = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0)  num_heads  = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqq") == 0)   seq_len_q  = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqk") == 0)   seq_len_k  = atoi(argv[++i]);
    else if (strcmp(argv[i], "-mask") == 0)   use_mask   = atoi(argv[++i]);
    else if (strcmp(argv[i], "-scale") == 0)  scale      = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] "
             "[-batch N] [-heads H] [-seqq Q] [-seqk K] [-mask 0|1] [-scale S]\n",
             argv[0]);
      return 0;
    }
  }

  if (!bench.csv) {
    printf("Softmax Bench: variant=%s batch=%u heads=%u seqq=%u seqk=%u mask=%u scale=%.6f  "
           "warmup=%d iterations=%d\n",
           softmax_variant_name(), batch_size, num_heads, seq_len_q, seq_len_k, use_mask, scale,
           bench.warmup, bench.iterations);
  }

  uint32_t total_rows = batch_size * num_heads * seq_len_q;
  uint32_t input_size = total_rows * seq_len_k;

  std::vector<data_t> h_input(input_size);

  srand(42);
  initialize_random(h_input);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t row_pitch_bytes = softmax_row_pitch_bytes(seq_len_k, sizeof(data_t));
  uint32_t buffer_bytes = total_rows * row_pitch_bytes;
  std::vector<uint8_t> h_input_pitched;

  if (softmax_uses_pitched_hbm()) {
    h_input_pitched.assign(buffer_bytes, 0);
    pack_rows_to_pitch(h_input_pitched, h_input, total_rows, seq_len_k, row_pitch_bytes);
    RT_CHECK(vx_mem_alloc_aligned(device, buffer_bytes, softmax_hbm_alloc_alignment(), VX_MEM_READ, &input_buffer));
    RT_CHECK(vx_mem_alloc_aligned(device, buffer_bytes, softmax_hbm_alloc_alignment(), softmax_output_mem_flags(), &output_buffer));
    RT_CHECK(vx_copy_to_dev(input_buffer, h_input_pitched.data(), 0, buffer_bytes));
  } else {
    RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
    RT_CHECK(vx_mem_alloc(device, buffer_bytes, softmax_output_mem_flags(), &output_buffer));
    RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));
  }

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_SOFTMAX;
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t rows_per_block = 1;
  uint32_t row_tiles = total_rows;
  kernel_arg.grid_dim[0] = softmax_grid_x(total_rows, threads_per_block,
                                          num_threads, num_cores,
                                          &rows_per_block, &row_tiles);
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.mask_addr = 0;
  kernel_arg.batch_size = batch_size;
  kernel_arg.num_heads = num_heads;
  kernel_arg.seq_len_q = seq_len_q;
  kernel_arg.seq_len_k = seq_len_k;
  kernel_arg.row_pitch_bytes = row_pitch_bytes;
  kernel_arg.use_mask = use_mask;
  kernel_arg.scale = scale;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

  // ---- Warmup ---------------------------------------------------------------
  printf("Warmup Start\n"); fflush(stdout);
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    printf("Warmup iteration %0d/%0d\n", i+1, bench.warmup); fflush(stdout);
  }

  // ---- Timed iterations -----------------------------------------------------
  vx_bench::Stats stats;
  printf("Start latency measurement.\n"); fflush(stdout);
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
    vx_bench::dump_iteration_perf(device, bench, i);
    printf("iteration %0d/%0d, elapsed:%f\n", i+1, bench.iterations, stats.last()); fflush(stdout);
  }

  stats.report("softmax", bench);

  if (!vx_bench::run_power_measurement(
          "softmax", bench, device, krnl_buffer, args_buffer)) {
    cleanup();
    return -1;
  }

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
