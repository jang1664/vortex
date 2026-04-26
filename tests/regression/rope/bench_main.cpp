// Benchmark harness for rope. See softmax/bench_main.cpp for design notes.

#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <assert.h>
#include <vortex.h>
#include "common.h"
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

using data_t = float;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h cos_buffer = nullptr;
vx_buffer_h sin_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (cos_buffer) vx_mem_free(cos_buffer);
  if (sin_buffer) vx_mem_free(sin_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void precompute_freqs(std::vector<data_t>& cos_t, std::vector<data_t>& sin_t,
                             uint32_t max_seq_len, uint32_t head_dim,
                             float theta_base = 10000.0f) {
  uint32_t half = head_dim / 2;
  cos_t.resize(max_seq_len * half);
  sin_t.resize(max_seq_len * half);
  for (uint32_t pos = 0; pos < max_seq_len; ++pos) {
    for (uint32_t i = 0; i < half; ++i) {
      float freq = std::pow(theta_base, -2.0f * i / head_dim);
      float theta = pos * freq;
      cos_t[pos * half + i] = std::cos(theta);
      sin_t[pos * half + i] = std::sin(theta);
    }
  }
}

static void rope_cpu(const std::vector<data_t>& in,
                     const std::vector<data_t>& cos_t,
                     const std::vector<data_t>& sin_t,
                     std::vector<data_t>& out,
                     uint32_t batch, uint32_t seq, uint32_t heads,
                     uint32_t head_dim, uint32_t pos_offset) {
  uint32_t half = head_dim / 2;
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      uint32_t pos = s + pos_offset;
      for (uint32_t h = 0; h < heads; ++h) {
        uint32_t base = ((b * seq + s) * heads + h) * head_dim;
        for (uint32_t p = 0; p < half; ++p) {
          float c = cos_t[pos * half + p];
          float si = sin_t[pos * half + p];
          float x0 = in[base + p];
          float x1 = in[base + p + half];
          out[base + p] = x0 * c - x1 * si;
          out[base + p + half] = x0 * si + x1 * c;
        }
      }
    }
  }
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& v : vec) v = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;
}

int main(int argc, char *argv[]) {
  auto bench = vx_bench::parse(argc, argv);

  uint32_t batch_size = 2;
  uint32_t seq_len = 8;
  uint32_t num_heads = 8;
  uint32_t head_dim = 64;
  uint32_t max_seq_len = 128;
  uint32_t pos_offset = 0;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0)       batch_size  = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0)    seq_len     = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0)  num_heads   = atoi(argv[++i]);
    else if (strcmp(argv[i], "-headdim") == 0) head_dim   = atoi(argv[++i]);
    else if (strcmp(argv[i], "-maxseq") == 0) max_seq_len = atoi(argv[++i]);
    else if (strcmp(argv[i], "-offset") == 0) pos_offset  = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [--warmup=N] [--iterations=N] [--csv] "
             "[--output=PATH] [--output-append] "
             "[-batch N] [-seq S] [-heads H] [-headdim D] [-maxseq M] [-offset O]\n", argv[0]);
      return 0;
    }
  }

  assert(head_dim % 2 == 0 && "head_dim must be even");

  if (!bench.csv) {
    printf("RoPE Bench: batch=%u seq=%u heads=%u headdim=%u maxseq=%u offset=%u  "
           "warmup=%d iterations=%d\n",
           batch_size, seq_len, num_heads, head_dim, max_seq_len, pos_offset,
           bench.warmup, bench.iterations);
  }

  uint32_t input_size = batch_size * seq_len * num_heads * head_dim;
  uint32_t freq_size  = max_seq_len * (head_dim / 2);
  std::vector<data_t> h_in(input_size), h_cos(freq_size), h_sin(freq_size);
  std::vector<data_t> h_out(input_size), h_ref(input_size);
  srand(42);
  initialize_random(h_in);
  precompute_freqs(h_cos, h_sin, max_seq_len, head_dim);
  rope_cpu(h_in, h_cos, h_sin, h_ref, batch_size, seq_len, num_heads, head_dim, pos_offset);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t input_bytes = input_size * sizeof(data_t);
  uint32_t freq_bytes  = freq_size  * sizeof(data_t);
  uint32_t output_bytes = input_size * sizeof(data_t);
  RT_CHECK(vx_mem_alloc(device, input_bytes,  VX_MEM_READ,  &input_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_bytes,   VX_MEM_READ,  &cos_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_bytes,   VX_MEM_READ,  &sin_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_in.data(),  0, input_bytes));
  RT_CHECK(vx_copy_to_dev(cos_buffer,   h_cos.data(), 0, freq_bytes));
  RT_CHECK(vx_copy_to_dev(sin_buffer,   h_sin.data(), 0, freq_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_ROPE;
  uint32_t total_pairs = batch_size * seq_len * num_heads * (head_dim / 2);
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t num_blocks = std::min((total_pairs + threads_per_block - 1) / threads_per_block,
                                 (uint32_t)num_cores);
  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer,  &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(cos_buffer,    &kernel_arg.cos_addr));
  RT_CHECK(vx_mem_address(sin_buffer,    &kernel_arg.sin_addr));
  kernel_arg.batch_size = batch_size;
  kernel_arg.seq_len = seq_len;
  kernel_arg.num_heads = num_heads;
  kernel_arg.head_dim = head_dim;
  kernel_arg.pos_offset = pos_offset;

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, output_bytes));
  int errors = 0;
  float max_diff = 0.0f;
  for (uint32_t i = 0; i < input_size; ++i) {
    float diff = std::abs(h_out[i] - h_ref[i]);
    max_diff = std::max(max_diff, diff);
    float thr = std::max(1e-5f, std::abs(h_ref[i]) * 0.01f);
    if (diff > thr) ++errors;
  }
  if (errors != 0) {
    printf("Validation FAILED: errors=%d max_diff=%.6f\n", errors, max_diff);
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

  stats.report("rope", bench);

  if (!bench.csv) {
    printf("\n[Performance]\n");
    vx_dump_perf(device, stdout);
  }

  cleanup();
  return 0;
}
