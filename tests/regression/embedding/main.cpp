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
vx_buffer_h indices_buffer = nullptr;
vx_buffer_h table_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (indices_buffer) vx_mem_free(indices_buffer);
  if (table_buffer) vx_mem_free(table_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
///////////////////////////////////////////////////////////////////////////////
void embedding_cpu(
    const std::vector<int32_t>& indices,
    const std::vector<data_t>& table,
    std::vector<data_t>& output,
    uint32_t num_indices,
    uint32_t hidden_dim,
    uint32_t vocab_size) {
  for (uint32_t i = 0; i < num_indices; ++i) {
    int32_t idx = indices[i];
    if ((uint32_t)idx >= vocab_size) {
      continue;
    }
    for (uint32_t j = 0; j < hidden_dim; ++j) {
      output[i * hidden_dim + j] = table[(uint32_t)idx * hidden_dim + j];
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
void initialize_random_table(std::vector<data_t>& vec) {
  for (size_t i = 0; i < vec.size(); ++i) {
    float x = -2.0f + 4.0f * (float((i * 2654435761u) % 1000) / 1000.0f);
    vec[i] = float_to_fp16(x);
  }
}

void initialize_random_indices(std::vector<int32_t>& indices, uint32_t vocab_size) {
  for (size_t i = 0; i < indices.size(); ++i) {
    indices[i] = (int32_t)(((i + 1) * 2654435761u) % vocab_size);
  }
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  // Default parameters (small self-test sizes)
  uint32_t vocab_size = 64;
  uint32_t hidden_dim = 32;
  uint32_t num_indices = 8;

  // Parse command line arguments
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-vocab") == 0) {
      vocab_size = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-hidden") == 0) {
      hidden_dim = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-n") == 0) {
      num_indices = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-vocab V] [-hidden H] [-n N]\n", argv[0]);
      return 0;
    }
  }

  printf("Embedding (Row Gather) Test Configuration:\n");
  printf("  Vocab Size:   %u\n", vocab_size);
  printf("  Hidden Dim:   %u\n", hidden_dim);
  printf("  Num Indices:  %u\n", num_indices);

  uint32_t table_size = vocab_size * hidden_dim;
  uint32_t output_size = num_indices * hidden_dim;

  // Allocate host memory
  std::vector<int32_t> h_indices(num_indices);
  std::vector<data_t> h_table(table_size);
  std::vector<data_t> h_output_gpu(output_size);
  std::vector<data_t> h_output_cpu(output_size);

  // Initialize data
  initialize_random_table(h_table);
  initialize_random_indices(h_indices, vocab_size);

  // Run CPU reference
  printf("Running CPU reference...\n");
  embedding_cpu(h_indices, h_table, h_output_cpu, num_indices, hidden_dim, vocab_size);

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
  uint32_t indices_bytes = num_indices * sizeof(int32_t);
  uint32_t table_bytes = table_size * sizeof(data_t);
  uint32_t output_bytes = output_size * sizeof(data_t);

  RT_CHECK(vx_mem_alloc(device, indices_bytes, VX_MEM_READ, &indices_buffer));
  RT_CHECK(vx_mem_alloc(device, table_bytes, VX_MEM_READ, &table_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));

  // Copy data to device
  RT_CHECK(vx_copy_to_dev(indices_buffer, h_indices.data(), 0, indices_bytes));
  RT_CHECK(vx_copy_to_dev(table_buffer, h_table.data(), 0, table_bytes));

  // Setup kernel arguments
  embedding_kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_EMBEDDING;

  // Grid/Block configuration - one logical work item per output element.
  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t total_elements = num_indices * hidden_dim;
  uint32_t num_blocks = std::min((total_elements + threads_per_block - 1) / threads_per_block,
                                 std::max(1u, (uint32_t)num_cores * 4));

  kernel_arg.grid_dim[0] = num_blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  // Buffer addresses
  RT_CHECK(vx_mem_address(indices_buffer, &kernel_arg.indices_addr));
  RT_CHECK(vx_mem_address(table_buffer, &kernel_arg.table_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));

  // Dimensions
  kernel_arg.num_indices = num_indices;
  kernel_arg.hidden_dim = hidden_dim;
  kernel_arg.vocab_size = vocab_size;

  printf("Grid: [%d, %d, %d]\n",
         kernel_arg.grid_dim[0], kernel_arg.grid_dim[1], kernel_arg.grid_dim[2]);
  printf("Block: [%d, %d, %d]\n",
         kernel_arg.block_dim[0], kernel_arg.block_dim[1], kernel_arg.block_dim[2]);

  // Upload kernel arguments
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(embedding_kernel_arg_t), &args_buffer));

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

  for (uint32_t i = 0; i < output_size; ++i) {
    float got = fp16_to_float(h_output_gpu[i]);
    float expected = fp16_to_float(h_output_cpu[i]);
    float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);

    // Embedding is a pure copy - values should match exactly (fp16 bit-exact).
    if (diff > 0.0f) {
      if (errors < 10) {
        printf("Error at %d: GPU=%.6f, CPU=%.6f, diff=%.6f\n",
               i, got, expected, diff);
      }
      ++errors;
    }
  }

  printf("  Max absolute diff: %.6f\n", max_diff);

  if (errors == 0) {
    printf("PASSED!\n");
  } else {
    printf("FAILED! (%d errors)\n", errors);
  }

  cleanup();
  return (errors == 0) ? 0 : -1;
}
