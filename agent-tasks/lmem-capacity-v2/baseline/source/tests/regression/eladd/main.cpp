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
vx_buffer_h input_a_buffer = nullptr;
vx_buffer_h input_b_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_a_buffer) vx_mem_free(input_a_buffer);
  if (input_b_buffer) vx_mem_free(input_b_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////
void eladd_cpu(
    const std::vector<data_t>& input_a,
    const std::vector<data_t>& input_b,
    std::vector<data_t>& output) {
  for (size_t i = 0; i < input_a.size(); ++i) {
    float a = fp16_to_float(input_a[i]);
    float b = fp16_to_float(input_b[i]);
    output[i] = float_to_fp16(a + b);
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
  // Default parameters
  uint32_t size = 8192;  // 8K elements
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-n") == 0) {
      size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-n SIZE]\n", argv[0]);
      return 0;
    }
  }
  
  printf("Element-wise Add Test Configuration:\n");
  printf("  Size: %d elements\n", size);
  
  // Allocate host memory
  std::vector<data_t> h_input_a(size);
  std::vector<data_t> h_input_b(size);
  std::vector<data_t> h_output_gpu(size);
  std::vector<data_t> h_output_cpu(size);
  
  // Initialize data
  srand(42);
  initialize_random(h_input_a);
  initialize_random(h_input_b);
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  eladd_cpu(h_input_a, h_input_b, h_output_cpu);
  
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
  uint32_t buffer_bytes = size * sizeof(data_t);
  
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_a_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_b_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_a_buffer, h_input_a.data(), 0, buffer_bytes));
  RT_CHECK(vx_copy_to_dev(input_b_buffer, h_input_b.data(), 0, buffer_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_ELADD;
  
  // Grid/Block configuration - simple 1D grid
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t num_blocks = std::min((size + threads_per_block - 1) / threads_per_block,
                                  (uint32_t)num_cores * 4);
  
  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  
  // Buffer addresses
  RT_CHECK(vx_mem_address(input_a_buffer, &kernel_arg.input_a_addr));
  RT_CHECK(vx_mem_address(input_b_buffer, &kernel_arg.input_b_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  
  // Dimensions
  kernel_arg.size = size;
  
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
  
  for (uint32_t i = 0; i < size; ++i) {
    float got = fp16_to_float(h_output_gpu[i]);
    float expected = fp16_to_float(h_output_cpu[i]);
    float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);
    
    // Check relative error
    float abs_threshold = 1e-6f;
    float rel_threshold = std::abs(expected) * 0.01f;  // 1%
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
