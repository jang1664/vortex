// Benchmark harness for softmax. Reuses the same kernel.vxbin built from
// kernel.cpp; differs from main.cpp only in that it (1) runs warmup +
// timed-iteration loops around vx_start/vx_ready_wait, (2) validates the
// output once before the timed loop, (3) prints latency stats at the end.
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

static void softmax_cpu(
    const std::vector<data_t>& input,
    std::vector<data_t>& output,
    uint32_t batch_size,
    uint32_t num_heads,
    uint32_t seq_len_q,
    uint32_t seq_len_k,
    bool use_mask,
    float scale) {
  for (uint32_t b = 0; b < batch_size; ++b) {
    for (uint32_t h = 0; h < num_heads; ++h) {
      for (uint32_t q = 0; q < seq_len_q; ++q) {
        uint32_t row_offset = ((b * num_heads + h) * seq_len_q + q) * seq_len_k;
        float max_val = -INFINITY;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) val = -INFINITY;
          max_val = std::max(max_val, val);
        }
        float sum = 0.0f;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) val = -INFINITY;
          float exp_val = std::exp(val - max_val);
          sum += exp_val;
        }
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) val = -INFINITY;
          float exp_val = std::exp(val - max_val);
          output[row_offset + k] = float_to_fp16(exp_val / sum);
        }
      }
    }
  }
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;
    val = float_to_fp16(x);
  }
}

int main(int argc, char *argv[]) {
  // Bench flags (--warmup / --iterations / --csv / --output / --output-append) — stripped from argv.
  auto bench = vx_bench::parse(argc, argv);

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
    printf("Softmax Bench: batch=%u heads=%u seqq=%u seqk=%u mask=%u scale=%.6f  "
           "warmup=%d iterations=%d\n",
           batch_size, num_heads, seq_len_q, seq_len_k, use_mask, scale,
           bench.warmup, bench.iterations);
  }

  uint32_t input_size = batch_size * num_heads * seq_len_q * seq_len_k;

  std::vector<data_t> h_input(input_size);
  std::vector<data_t> h_output_gpu(input_size);
  std::vector<data_t> h_output_cpu(input_size);

  srand(42);
  initialize_random(h_input);

  softmax_cpu(h_input, h_output_cpu, batch_size, num_heads,
              seq_len_q, seq_len_k, use_mask != 0, scale);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t buffer_bytes = input_size * sizeof(data_t);
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ | VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_SOFTMAX;
  uint32_t total_rows = batch_size * num_heads * seq_len_q;
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  kernel_arg.grid_dim[0] = total_rows;
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
  kernel_arg.use_mask = use_mask;
  kernel_arg.scale = scale;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

  // ---- Validate once before timed loop --------------------------------------
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, buffer_bytes));

  int errors = 0;
  float max_diff = 0.0f;
  for (uint32_t i = 0; i < input_size; ++i) {
    float got = fp16_to_float(h_output_gpu[i]);
    float expected = fp16_to_float(h_output_cpu[i]);
    float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);
    float threshold = std::max(1e-5f, std::abs(expected) * 0.01f);
    if (diff > threshold) ++errors;
  }
  if (errors != 0) {
    printf("Validation FAILED before bench loop: errors=%d  max_diff=%.6f\n",
           errors, max_diff);
    cleanup();
    return -1;
  }

  // ---- Warmup ---------------------------------------------------------------
  for (int i = 0; i < bench.warmup; ++i) {
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  }

  // ---- Timed iterations -----------------------------------------------------
  vx_bench::Stats stats;
  for (int i = 0; i < bench.iterations; ++i) {
    vx_bench::Stopwatch sw;
    sw.start();
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    stats.record(sw.stop_us());
  }

  stats.report("softmax", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
