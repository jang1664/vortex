#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <functional>
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
void cpu_rsqrt(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = 1.0f / std::sqrt(input[i]);
  }
}

void cpu_sin(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::sin(input[i]);
  }
}

void cpu_cos(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::cos(input[i]);
  }
}

void cpu_exp(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::exp(input[i]);
  }
}

void cpu_log(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::log(input[i]);
  }
}

void cpu_neg(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = -input[i];
  }
}

void cpu_abs(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::abs(input[i]);
  }
}

void cpu_sqrt(const std::vector<data_t>& input, std::vector<data_t>& output) {
  for (size_t i = 0; i < input.size(); ++i) {
    output[i] = std::sqrt(input[i]);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
void initialize_random(std::vector<data_t>& vec, float min_val = 0.1f, float max_val = 4.0f) {
  for (auto& val : vec) {
    val = min_val + static_cast<float>(rand()) / RAND_MAX * (max_val - min_val);
  }
}

void initialize_for_trig(std::vector<data_t>& vec) {
  for (auto& val : vec) {
    val = static_cast<float>(rand()) / RAND_MAX * 6.28f - 3.14f;  // [-pi, pi]
  }
}

struct OpInfo {
  uint32_t kernel_id;
  const char* name;
  std::function<void(const std::vector<data_t>&, std::vector<data_t>&)> cpu_fn;
  bool needs_positive;
  bool is_trig;
};

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters
  uint32_t size = 8192;
  uint32_t op_id = KERNEL_RSQRT;
  
  OpInfo ops[] = {
    {KERNEL_RSQRT, "rsqrt", cpu_rsqrt, true, false},
    {KERNEL_SIN,   "sin",   cpu_sin,   false, true},
    {KERNEL_COS,   "cos",   cpu_cos,   false, true},
    {KERNEL_EXP,   "exp",   cpu_exp,   false, false},
    {KERNEL_LOG,   "log",   cpu_log,   true, false},
    {KERNEL_NEG,   "neg",   cpu_neg,   false, false},
    {KERNEL_ABS,   "abs",   cpu_abs,   false, false},
    {KERNEL_SQRT,  "sqrt",  cpu_sqrt,  true, false},
  };
  
  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-n") == 0) {
      size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-op") == 0) {
      const char* op_name = argv[++i];
      for (const auto& op : ops) {
        if (strcmp(op_name, op.name) == 0) {
          op_id = op.kernel_id;
          break;
        }
      }
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-n SIZE] [-op OPERATION]\n", argv[0]);
      printf("Operations: rsqrt, sin, cos, exp, log, neg, abs, sqrt\n");
      return 0;
    }
  }
  
  const OpInfo& current_op = ops[op_id];
  
  printf("Element-wise Unary Test Configuration:\n");
  printf("  Operation: %s\n", current_op.name);
  printf("  Size: %d elements\n", size);
  
  // Allocate host memory
  std::vector<data_t> h_input(size);
  std::vector<data_t> h_output_gpu(size);
  std::vector<data_t> h_output_cpu(size);
  
  // Initialize data
  srand(42);
  if (current_op.is_trig) {
    initialize_for_trig(h_input);
  } else if (current_op.needs_positive) {
    initialize_random(h_input, 0.1f, 4.0f);  // Positive values for sqrt/rsqrt/log
  } else {
    initialize_random(h_input, -2.0f, 2.0f);
  }
  
  // Run CPU reference
  printf("Running CPU reference...\n");
  current_op.cpu_fn(h_input, h_output_cpu);
  
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
  
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_WRITE, &output_buffer));
  
  // Copy data to device
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));
  
  // Setup kernel arguments
  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = op_id;
  
  // Grid/Block configuration
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
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  
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
  
  for (uint32_t i = 0; i < size; ++i) {
    float diff = std::abs(h_output_gpu[i] - h_output_cpu[i]);
    max_diff = std::max(max_diff, diff);
    
    // Use relative error
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
