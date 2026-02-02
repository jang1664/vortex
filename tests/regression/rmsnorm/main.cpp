#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <assert.h>
#include <vortex.h>
#include "common.h"

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

using data_t = float;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h gamma_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (gamma_buffer) vx_mem_free(gamma_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////
void rmsnorm_cpu(
    const std::vector<data_t>& input,
    const std::vector<data_t>& gamma,
    std::vector<data_t>& output,
    uint32_t batch_size,
    uint32_t seq_len,
    uint32_t hidden_dim,
    float eps) {
  
  for (uint32_t b = 0; b < batch_size; ++b) {
    for (uint32_t s = 0; s < seq_len; ++s) {
      uint32_t token_idx = b * seq_len + s;
      uint32_t offset = token_idx * hidden_dim;
      
      // Compute sum of squares
      float sum_sq = 0.0f;
      for (uint32_t i = 0; i < hidden_dim; ++i) {
        float val = input[offset + i];
        sum_sq += val * val;
      }
      
      // Compute RMS normalization factor
      float mean_sq = sum_sq / hidden_dim;
      float rms_norm = 1.0f / std::sqrt(mean_sq + eps);
      
      // Normalize and apply gamma
      for (uint32_t i = 0; i < hidden_dim; ++i) {
        output[offset + i] = input[offset + i] * rms_norm * gamma[i];
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
    val = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;  // [-1, 1]
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters
  uint32_t batch_size = 2;
  uint32_t seq_len = 8;
  uint32_t hidden_dim = 128;
  float eps = 1e-6f;
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) {
      batch_size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-seq") == 0) {
      seq_len = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-hidden") == 0) {
      hidden_dim = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-eps") == 0) {
      eps = atof(argv[++i]);
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch N] [-seq S] [-hidden H] [-eps E]\n", argv[0]);
      return 0;
    }
  }
  
  printf("RMSNorm Test Configuration:\n");
  printf("  Batch Size:   %d\n", batch_size);
  printf("  Seq Length:   %d\n", seq_len);
  printf("  Hidden Dim:   %d\n", hidden_dim);
  printf("  Epsilon:      %e\n", eps);
  
  uint32_t total_tokens = batch_size * seq_len;
  uint32_t input_size = total_tokens * hidden_dim;
  
  // Allocate host memory
  std::vector<data_t> h_input(input_size);
  std::vector<data_t> h_gamma(hidden_dim);
  std::vector<data_t> h_output_gpu(input_size);
  std::vector<data_t> h_output_cpu(input_size);
  
  // Initialize data
  srand(42);
  initialize_random(h_input);
  initialize_random(h_gamma);
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  rmsnorm_cpu(h_input, h_gamma, h_output_cpu, batch_size, seq_len, hidden_dim, eps);
  
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
  uint32_t gamma_bytes = hidden_dim * sizeof(data_t);
  uint32_t output_bytes = input_size * sizeof(data_t);
  
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, gamma_bytes, VX_MEM_READ, &gamma_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, input_bytes));
  RT_CHECK(vx_copy_to_dev(gamma_buffer, h_gamma.data(), 0, gamma_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_RMSNORM;
  
  // Grid/Block configuration
  // Each block processes one token
  // Use multiple threads per block for shared memory reduction
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  kernel_arg.grid_dim[0] = total_tokens;  // One block per token
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  
  // Buffer addresses
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_mem_address(gamma_buffer, &kernel_arg.gamma_addr));
  
  // Dimensions
  kernel_arg.batch_size = batch_size;
  kernel_arg.seq_len = seq_len;
  kernel_arg.hidden_dim = hidden_dim;
  kernel_arg.eps = eps;
  
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
    float diff = std::abs(h_output_gpu[i] - h_output_cpu[i]);
    max_diff = std::max(max_diff, diff);
    
    // Use relative error tolerance (similar to gemm_fpint)
    // Allow small absolute error OR small relative error
    float abs_threshold = 1e-5f;  // Absolute tolerance for values near zero
    float rel_threshold = std::abs(h_output_cpu[i]) * 0.01f;  // 1% relative error
    float threshold = std::max(abs_threshold, rel_threshold);
    
    if (diff > threshold) {
      if (errors < 10) {
        float rel_error = (h_output_cpu[i] != 0.0f) ? diff / std::abs(h_output_cpu[i]) : 0.0f;
        max_rel_error = std::max(max_rel_error, rel_error);
        printf("Error at %d: GPU=%.6f, CPU=%.6f, diff=%.6f, rel_err=%.2f%%\n", 
               i, h_output_gpu[i], h_output_cpu[i], diff, rel_error * 100.0f);
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
