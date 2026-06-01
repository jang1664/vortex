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
vx_buffer_h mask_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (mask_buffer) vx_mem_free(mask_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////
void softmax_cpu(
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
        
        // Find max for numerical stability
        float max_val = -INFINITY;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) {
            val = -INFINITY;
          }
          max_val = std::max(max_val, val);
        }
        
        // Compute exp and sum
        float sum = 0.0f;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) {
            val = -INFINITY;
          }
          float exp_val = std::exp(val - max_val);
          sum += exp_val;
        }
        
        // Normalize
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = fp16_to_float(input[row_offset + k]) * scale;
          if (use_mask && k > q) {
            val = -INFINITY;
          }
          float exp_val = std::exp(val - max_val);
          output[row_offset + k] = float_to_fp16(exp_val / sum);
        }
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
void initialize_random(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    float x = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;  // [-2, 2]
    val = float_to_fp16(x);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters (typical for attention)
  uint32_t batch_size = 2;
  uint32_t num_heads = 16;
  uint32_t seq_len_q = 8;
  uint32_t seq_len_k = 8;
  uint32_t use_mask = 1;  // Causal masking by default
  float scale = 1.0f / std::sqrt(64.0f);  // 1/sqrt(d_k), assuming head_dim=64
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) {
      batch_size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-heads") == 0) {
      num_heads = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-seqq") == 0) {
      seq_len_q = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-seqk") == 0) {
      seq_len_k = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-mask") == 0) {
      use_mask = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-scale") == 0) {
      scale = atof(argv[++i]);
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch N] [-heads H] [-seqq Q] [-seqk K] [-mask 0|1] [-scale S]\n", argv[0]);
      return 0;
    }
  }
  
  printf("Softmax Test Configuration:\n");
  printf("  Batch Size:   %d\n", batch_size);
  printf("  Num Heads:    %d\n", num_heads);
  printf("  Seq Len Q:    %d\n", seq_len_q);
  printf("  Seq Len K:    %d\n", seq_len_k);
  printf("  Use Mask:     %d\n", use_mask);
  printf("  Scale:        %.6f\n", scale);
  
  uint32_t input_size = batch_size * num_heads * seq_len_q * seq_len_k;
  
  // Allocate host memory
  std::vector<data_t> h_input(input_size);
  std::vector<data_t> h_output_gpu(input_size);
  std::vector<data_t> h_output_cpu(input_size);
  
  // Initialize data
  srand(42);
  initialize_random(h_input);
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  softmax_cpu(h_input, h_output_cpu, batch_size, num_heads, 
              seq_len_q, seq_len_k, use_mask != 0, scale);
  
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
  uint32_t buffer_bytes = input_size * sizeof(data_t);
  
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
  // Output buffer needs READ+WRITE because kernel reads back intermediate exp values
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ | VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_SOFTMAX;
  
  // Grid/Block configuration
  // Each block processes one row (one query position across key dimension)
  uint32_t total_rows = batch_size * num_heads * seq_len_q;
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  
  kernel_arg.grid_dim[0] = total_rows;  // One block per row
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  
  // Buffer addresses
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.mask_addr = 0;  // Not using separate mask buffer
  
  // Dimensions
  kernel_arg.batch_size = batch_size;
  kernel_arg.num_heads = num_heads;
  kernel_arg.seq_len_q = seq_len_q;
  kernel_arg.seq_len_k = seq_len_k;
  kernel_arg.use_mask = use_mask;
  kernel_arg.scale = scale;
  
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
  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, buffer_bytes));
  
  // Print performance statistics
  printf("\n[Performance]\n");
  vx_dump_perf(device, stdout);
  
  // Verify results
  printf("Verifying results...\n");
  
  int errors = 0;
  float max_diff = 0.0f;
  float max_rel_error = 0.0f;
  
  // Verify: all outputs should be non-negative and sum to ~1.0
  for (uint32_t b = 0; b < batch_size; ++b) {
    for (uint32_t h = 0; h < num_heads; ++h) {
      for (uint32_t q = 0; q < seq_len_q; ++q) {
        uint32_t row_offset = ((b * num_heads + h) * seq_len_q + q) * seq_len_k;
        
        float sum_gpu = 0.0f;
        float sum_cpu = 0.0f;
        
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          uint32_t idx = row_offset + k;
          float got = fp16_to_float(h_output_gpu[idx]);
          float expected = fp16_to_float(h_output_cpu[idx]);
          float diff = std::abs(got - expected);
          max_diff = std::max(max_diff, diff);
          
          sum_gpu += got;
          sum_cpu += expected;
          
          // Check relative error
          float abs_threshold = 1e-5f;
          float rel_threshold = std::abs(expected) * 0.01f;  // 1%
          float threshold = std::max(abs_threshold, rel_threshold);
          
          if (diff > threshold) {
            if (errors < 10) {
              float rel_error = (expected != 0.0f) ? diff / std::abs(expected) : 0.0f;
              max_rel_error = std::max(max_rel_error, rel_error);
              printf("Error at [%d,%d,%d,%d]: GPU=%.6f, CPU=%.6f, diff=%.6f, rel_err=%.2f%%\n", 
                     b, h, q, k, got, expected, diff, rel_error * 100.0f);
            }
            ++errors;
          }
        }
        
        // Check if sums are close to 1.0
        if (std::abs(sum_gpu - 1.0f) > 2e-3f) {
          if (errors < 10) {
            printf("Row sum error at [%d,%d,%d]: GPU sum=%.6f (expected ~1.0)\n", 
                   b, h, q, sum_gpu);
          }
          ++errors;
        }
      }
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
