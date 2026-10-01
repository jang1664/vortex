#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <assert.h>
#include <vortex.h>
#include "common.h"
#include "../vector_common/fp16.h"

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
     cleanup();                                                 \
     exit(-1);                                                  \
   } while (false)

#define FLOAT_ULP 6
#define M_PI 3.14159265358979323846

using data_t = fp16_t;

#ifndef ROPE_VARIANT_TAG
#define ROPE_VARIANT_TAG 0
#endif

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

///////////////////////////////////////////////////////////////////////////////
// Helper: Precompute RoPE frequencies
///////////////////////////////////////////////////////////////////////////////
void precompute_freqs(
    std::vector<data_t>& cos_table,
    std::vector<data_t>& sin_table,
    uint32_t max_seq_len,
    uint32_t head_dim,
    float theta_base = 10000.0f) {
  
  uint32_t half_dim = head_dim / 2;
  cos_table.resize(max_seq_len * half_dim);
  sin_table.resize(max_seq_len * half_dim);
  
  for (uint32_t pos = 0; pos < max_seq_len; ++pos) {
    for (uint32_t i = 0; i < half_dim; ++i) {
      // Frequency: theta_i = base^(-2i/d)
      float freq = std::pow(theta_base, -2.0f * i / head_dim);
      float theta = pos * freq;
      
      cos_table[pos * half_dim + i] = float_to_fp16(std::cos(theta));
      sin_table[pos * half_dim + i] = float_to_fp16(std::sin(theta));
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////
void rope_cpu(
    const std::vector<data_t>& input,
    const std::vector<data_t>& cos_table,
    const std::vector<data_t>& sin_table,
    std::vector<data_t>& output,
    uint32_t batch_size,
    uint32_t seq_len,
    uint32_t num_heads,
    uint32_t head_dim,
    uint32_t pos_offset) {
  
  uint32_t half_dim = head_dim / 2;
  
  for (uint32_t b = 0; b < batch_size; ++b) {
    for (uint32_t s = 0; s < seq_len; ++s) {
      uint32_t pos = s + pos_offset;
      
      for (uint32_t h = 0; h < num_heads; ++h) {
        uint32_t base_idx = ((b * seq_len + s) * num_heads + h) * head_dim;
        
        // Apply rotation to each pair
        for (uint32_t p = 0; p < half_dim; ++p) {
          float cos_val = fp16_to_float(cos_table[pos * half_dim + p]);
          float sin_val = fp16_to_float(sin_table[pos * half_dim + p]);
          
          float x0 = fp16_to_float(input[base_idx + p]);
          float x1 = fp16_to_float(input[base_idx + p + half_dim]);
          
          output[base_idx + p] = float_to_fp16(x0 * cos_val - x1 * sin_val);
          output[base_idx + p + half_dim] = float_to_fp16(x0 * sin_val + x1 * cos_val);
        }
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
int float_compare(float a, float b, int ulp = FLOAT_ULP) {
  union fi_t { float f; int32_t i; };
  fi_t fa, fb;
  fa.f = a;
  fb.f = b;
  auto d = std::abs(fa.i - fb.i);
  return d <= ulp;
}

void initialize_random(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;  // [-1, 1]
    val = float_to_fp16(x);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters (typical for small LLaMA-style model)
  uint32_t batch_size = 2;
  uint32_t seq_len = 8;
  uint32_t num_heads = 8;
  uint32_t head_dim = 64;  // Must be even
  uint32_t max_seq_len = 128;
  uint32_t pos_offset = 0;
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) {
      batch_size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-seq") == 0) {
      seq_len = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-heads") == 0) {
      num_heads = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-headdim") == 0) {
      head_dim = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-maxseq") == 0) {
      max_seq_len = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-offset") == 0) {
      pos_offset = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch N] [-seq S] [-heads H] [-headdim D] [-maxseq M] [-offset O]\n", argv[0]);
      return 0;
    }
  }
  
  assert(head_dim % 2 == 0 && "head_dim must be even");
  
  printf("RoPE Test Configuration:\n");
  printf("  Batch Size:   %d\n", batch_size);
  printf("  Seq Length:   %d\n", seq_len);
  printf("  Num Heads:    %d\n", num_heads);
  printf("  Head Dim:     %d\n", head_dim);
  printf("  Max Seq Len:  %d\n", max_seq_len);
  printf("  Pos Offset:   %d\n", pos_offset);
#if ROPE_VARIANT_TAG == 1
  printf("  Variant:      task_chunk16\n");
#else
  printf("  Variant:      baseline\n");
#endif
  
  uint32_t input_size = batch_size * seq_len * num_heads * head_dim;
  uint32_t freq_size = max_seq_len * (head_dim / 2);
  
  // Allocate host memory
  std::vector<data_t> h_input(input_size);
  std::vector<data_t> h_cos(freq_size);
  std::vector<data_t> h_sin(freq_size);
  std::vector<data_t> h_output_gpu(input_size);
  std::vector<data_t> h_output_cpu(input_size);
  
  // Initialize data
  srand(42);
  initialize_random(h_input);
  precompute_freqs(h_cos, h_sin, max_seq_len, head_dim);
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  rope_cpu(h_input, h_cos, h_sin, h_output_cpu, 
           batch_size, seq_len, num_heads, head_dim, pos_offset);
  
  // Initialize Vortex
  printf("Initializing Vortex...\n");
  
  RT_CHECK(vx_dev_open(&device));
  
  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  
  printf("Device Caps: cores=%ld, warps=%ld, threads=%ld\n", 
         num_cores, num_warps, num_threads);
  
  // Allocate device memory
  uint32_t input_bytes = input_size * sizeof(data_t);
  uint32_t freq_bytes = freq_size * sizeof(data_t);
  uint32_t output_bytes = input_size * sizeof(data_t);
  
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_bytes, VX_MEM_READ, &cos_buffer));
  RT_CHECK(vx_mem_alloc(device, freq_bytes, VX_MEM_READ, &sin_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(cos_buffer, h_cos.data(), 0, freq_bytes));
  RT_CHECK(vx_copy_to_dev(sin_buffer, h_sin.data(), 0, freq_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_ROPE;
  
  // Grid/Block configuration
  // Use grid-stride loop pattern
#if ROPE_VARIANT_TAG == 1
  const uint32_t chunks_per_head = ((head_dim / 2) + 15u) >> 4;
  const uint32_t work_items =
      batch_size * seq_len * num_heads * chunks_per_head;
#else
  const uint32_t work_items =
      batch_size * seq_len * num_heads * (head_dim / 2);
#endif
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t num_blocks = std::min((work_items + threads_per_block - 1) / threads_per_block,
                                  (uint32_t)num_cores);
  
  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  
  // Buffer addresses
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(cos_buffer, &kernel_arg.cos_addr));
  RT_CHECK(vx_mem_address(sin_buffer, &kernel_arg.sin_addr));
  
  // Dimensions
  kernel_arg.batch_size = batch_size;
  kernel_arg.seq_len = seq_len;
  kernel_arg.num_heads = num_heads;
  kernel_arg.head_dim = head_dim;
  kernel_arg.pos_offset = pos_offset;
  
  printf("Grid: [%d, %d, %d]\n", 
         kernel_arg.grid_dim[0], kernel_arg.grid_dim[1], kernel_arg.grid_dim[2]);
  printf("Block: [%d, %d, %d]\n", 
         kernel_arg.block_dim[0], kernel_arg.block_dim[1], kernel_arg.block_dim[2]);
  
  // Upload kernel arguments
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  
  // Upload kernel binary
  printf("Uploading kernel...\n");
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  
  // Run kernel
  printf("Running kernel...\n");
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  
  // Copy results back
  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, output_bytes));
  
  // Print performance statistics
  printf("\n[Performance]\n");
  vx_dump_perf(device, stdout);
  
  // Verify results
  printf("Verifying results...\n");
  
  int errors = 0;
  float max_diff = 0.0f;
  float max_rel_error = 0.0f;
  
  for (uint32_t i = 0; i < input_size; ++i) {
    float got = fp16_to_float(h_output_gpu[i]);
    float expected = fp16_to_float(h_output_cpu[i]);
    float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);
    
    // Use relative error tolerance (for trigonometric operations)
    float abs_threshold = 1e-5f;  // Absolute tolerance for values near zero
    float rel_threshold = std::abs(expected) * 0.01f;  // 1% relative error
    float threshold = std::max(abs_threshold, rel_threshold);
    
    if (diff > threshold) {
      if (errors < 10) {
        float rel_error = (expected != 0.0f) ? diff / std::abs(expected) : 0.0f;
        max_rel_error = std::max(max_rel_error, rel_error);
        printf("Error at %d: GPU=%.6f, CPU=%.6f, diff=%.6f, rel_err=%.2f%%\n", 
               i, got, expected, diff, rel_error * 100.0f);
      }
      ++errors;
    }
  }
  
  printf("  Max absolute diff: %.6f\n", max_diff);
  printf("  Max relative error: %.2f%%\n", max_rel_error * 100.0f);
  
  if (errors == 0) {
    printf("PASSED!\n");
  } else {
    printf("FAILED! (%d errors)\n", errors);
  }
  
  cleanup();
  return (errors == 0) ? 0 : -1;
}
