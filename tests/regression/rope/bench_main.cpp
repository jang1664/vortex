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
      cos_t[pos * half + i] = float_to_fp16(std::cos(theta));
      sin_t[pos * half + i] = float_to_fp16(std::sin(theta));
    }
  }
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& v : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;
    v = float_to_fp16(x);
  }
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
  srand(42);
  initialize_random(h_in);
  precompute_freqs(h_cos, h_sin, max_seq_len, head_dim);

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
