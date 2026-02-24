#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <functional>
#include <cfloat>
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

using data_t = float;

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

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementations
///////////////////////////////////////////////////////////////////////////////
void cpu_mean(const std::vector<data_t>& input, std::vector<data_t>& output,
              uint32_t batch_size, uint32_t reduce_dim) {
  for (uint32_t row = 0; row < batch_size; ++row) {
    float sum = 0.0f;
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      sum += input[row * reduce_dim + col];
    }
    output[row] = sum / static_cast<float>(reduce_dim);
  }
}

void cpu_sum(const std::vector<data_t>& input, std::vector<data_t>& output,
             uint32_t batch_size, uint32_t reduce_dim) {
  for (uint32_t row = 0; row < batch_size; ++row) {
    float sum = 0.0f;
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      sum += input[row * reduce_dim + col];
    }
    output[row] = sum;
  }
}

void cpu_max(const std::vector<data_t>& input, std::vector<data_t>& output,
             uint32_t batch_size, uint32_t reduce_dim) {
  for (uint32_t row = 0; row < batch_size; ++row) {
    float max_val = -FLT_MAX;
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      max_val = std::max(max_val, input[row * reduce_dim + col]);
    }
    output[row] = max_val;
  }
}

void cpu_min(const std::vector<data_t>& input, std::vector<data_t>& output,
             uint32_t batch_size, uint32_t reduce_dim) {
  for (uint32_t row = 0; row < batch_size; ++row) {
    float min_val = FLT_MAX;
    for (uint32_t col = 0; col < reduce_dim; ++col) {
      min_val = std::min(min_val, input[row * reduce_dim + col]);
    }
    output[row] = min_val;
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
void initialize_random(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    val = static_cast<float>(rand()) / RAND_MAX * 4.0f - 2.0f;  // [-2, 2]
  }
}

struct OpInfo {
  uint32_t kernel_id;
  const char* name;
  std::function<void(const std::vector<data_t>&, std::vector<data_t>&, uint32_t, uint32_t)> cpu_fn;
};

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters
  uint32_t batch_size = 128;
  uint32_t reduce_dim = 512;
  uint32_t op_id = KERNEL_MEAN;
  
  OpInfo ops[] = {
    {KERNEL_MEAN, "mean", cpu_mean},
    {KERNEL_SUM,  "sum",  cpu_sum},
    {KERNEL_MAX,  "max",  cpu_max},
    {KERNEL_MIN,  "min",  cpu_min},
  };
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-b") == 0) {
      batch_size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-r") == 0) {
      reduce_dim = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-op") == 0) {
      const char* op_name = argv[++i];
      for (const auto& op : ops) {
        if (strcmp(op_name, op.name) == 0) {
          op_id = op.kernel_id;
          break;
        }
      }
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-b BATCH_SIZE] [-r REDUCE_DIM] [-op OPERATION]\n", argv[0]);
      printf("Operations: mean, sum, max, min\n");
      return 0;
    }
  }
  
  const OpInfo& current_op = ops[op_id];
  
  printf("Reduction Test Configuration:\n");
  printf("  Operation: %s\n", current_op.name);
  printf("  Batch size: %d\n", batch_size);
  printf("  Reduce dim: %d\n", reduce_dim);
  
  // Allocate host memory
  uint32_t input_size = batch_size * reduce_dim;
  std::vector<data_t> h_input(input_size);
  std::vector<data_t> h_output_gpu(batch_size);
  std::vector<data_t> h_output_cpu(batch_size);
  
  // Initialize data
  srand(42);
  initialize_random(h_input);
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  current_op.cpu_fn(h_input, h_output_cpu, batch_size, reduce_dim);
  
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
  uint32_t output_bytes = batch_size * sizeof(data_t);
  
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, input_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = op_id;
  
  // Grid/Block configuration - one thread per row
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t num_blocks = std::min((batch_size + threads_per_block - 1) / threads_per_block,
                                  (uint32_t)num_cores * 4);
  
  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  
  // Buffer addresses
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  
  kernel_arg.batch_size = batch_size;
  kernel_arg.reduce_dim = reduce_dim;
  
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
  
  for (uint32_t i = 0; i < batch_size; ++i) {
    float diff = std::abs(h_output_gpu[i] - h_output_cpu[i]);
    max_diff = std::max(max_diff, diff);
    
    float rel_threshold = std::abs(h_output_cpu[i]) * 0.001f + 1e-5f;
    if (diff > rel_threshold) {
      if (errors < 10) {
        printf("Error at [%d]: GPU=%.6f, CPU=%.6f, diff=%.6f\n",
               i, h_output_gpu[i], h_output_cpu[i], diff);
      }
      ++errors;
    }
  }
  
  printf("\nMax diff: %.6f\n", max_diff);
  
  if (errors == 0) {
    printf("PASSED!\n");
  } else {
    printf("FAILED! %d errors\n", errors);
  }
  
  cleanup();
  return errors ? -1 : 0;
}
