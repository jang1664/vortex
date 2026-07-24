#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

#include <vortex.h>

#include "common.h"
#include "../vector_common/fp16.h"

using data_t = fp16_t;

#ifndef HADAMARD_VARIANT_TAG
#define HADAMARD_VARIANT_TAG 0
#endif

#define RT_CHECK(_expr)                                         \
  do {                                                          \
    int _ret = _expr;                                           \
    if (0 == _ret)                                              \
      break;                                                    \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);    \
    cleanup();                                                  \
    exit(-1);                                                   \
  } while (false)

static const char* kernel_file = "kernel.vxbin";

static vx_device_h device = nullptr;
static vx_buffer_h krnl_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static vx_buffer_h input_buffer = nullptr;
static vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static uint32_t next_power_of_two(uint32_t value) {
  if (value <= 1) {
    return 1;
  }

  --value;
  value |= value >> 1;
  value |= value >> 2;
  value |= value >> 4;
  value |= value >> 8;
  value |= value >> 16;
  return value + 1;
}

static void hadamard_cpu(
    const std::vector<data_t>& input,
    std::vector<data_t>& output,
    uint32_t rows,
    uint32_t dim,
    uint32_t padded_dim) {
  const float scale = 1.0f / std::sqrt(static_cast<float>(dim));
  std::vector<float> buf(padded_dim);

  for (uint32_t row = 0; row < rows; ++row) {
    const uint32_t row_offset = row * dim;
    for (uint32_t i = 0; i < padded_dim; ++i) {
      buf[i] = (i < dim) ? fp16_to_float(input[row_offset + i]) : 0.0f;
    }

    for (uint32_t stride = 1; stride < padded_dim; stride <<= 1) {
      const uint32_t step = stride << 1;
      for (uint32_t base = 0; base < padded_dim; base += step) {
        for (uint32_t i = 0; i < stride; ++i) {
          const float a = buf[base + i];
          const float b = buf[base + i + stride];
          buf[base + i] = a + b;
          buf[base + i + stride] = a - b;
        }
      }
    }

    for (uint32_t i = 0; i < dim; ++i) {
      output[row_offset + i] = float_to_fp16(buf[i] * scale);
    }
  }
}

static void initialize_random(std::vector<data_t>& vec) {
  for (auto& value : vec) {
    const float x = static_cast<float>(rand()) / RAND_MAX * 2.0f - 1.0f;
    value = float_to_fp16(x);
  }
}

static void print_usage(const char* prog) {
  printf("Usage: %s [-rows N] [-dim D] [-seed S] [-k kernel.vxbin]\n", prog);
}

int main(int argc, char *argv[]) {
  uint32_t rows = 4;
  uint32_t dim = 96;
  uint32_t seed = 42;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-rows") == 0 && i + 1 < argc) {
      rows = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-dim") == 0 && i + 1 < argc) {
      dim = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-seed") == 0 && i + 1 < argc) {
      seed = static_cast<uint32_t>(atoi(argv[++i]));
    } else if (strcmp(argv[i], "-k") == 0 && i + 1 < argc) {
      kernel_file = argv[++i];
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      print_usage(argv[0]);
      return 0;
    } else {
      print_usage(argv[0]);
      return -1;
    }
  }

  if (rows == 0 || dim == 0 || dim > (1u << 30)) {
    fprintf(stderr, "Invalid shape: rows=%u dim=%u\n", rows, dim);
    return -1;
  }

  const uint32_t padded_dim = next_power_of_two(dim);
  const uint64_t numel64 = static_cast<uint64_t>(rows) * dim;
  if (numel64 > std::numeric_limits<uint32_t>::max()) {
    fprintf(stderr, "Input is too large: rows=%u dim=%u\n", rows, dim);
    return -1;
  }
  const uint32_t numel = static_cast<uint32_t>(numel64);
  const uint64_t buffer_bytes = static_cast<uint64_t>(numel) * sizeof(data_t);

  printf("Hadamard Test Configuration:\n");
  printf("  Rows:       %u\n", rows);
  printf("  Dim:        %u\n", dim);
  printf("  Padded Dim: %u\n", padded_dim);
  printf("  Seed:       %u\n", seed);
#if HADAMARD_VARIANT_TAG == 1
  printf("  Variant:    adaptive_row\n");
#else
  printf("  Variant:    multiwarp_row\n");
#endif

  std::vector<data_t> h_input(numel);
  std::vector<data_t> h_output_gpu(numel);
  std::vector<data_t> h_output_cpu(numel);

  srand(seed);
  initialize_random(h_input);
  hadamard_cpu(h_input, h_output_cpu, rows, dim, padded_dim);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads, local_mem_size;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));

  const uint32_t max_threads_per_block =
      std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
#if HADAMARD_VARIANT_TAG == 1
  const bool small_transform =
      padded_dim <= static_cast<uint32_t>(num_threads * 4u);
  const bool one_warp_has_enough_rows =
      rows >= num_warps && (small_transform || rows == num_warps);
  const uint32_t threads_per_block =
      one_warp_has_enough_rows ? static_cast<uint32_t>(num_threads)
                               : max_threads_per_block;
#else
  const uint32_t threads_per_block = max_threads_per_block;
#endif
  printf("  Launch:     %u threads/row\n", threads_per_block);
  uint32_t max_localmem = 0;
  RT_CHECK(vx_check_occupancy(device, threads_per_block, &max_localmem));
  const uint32_t scratch_bytes = padded_dim * sizeof(float);
  if (scratch_bytes > max_localmem) {
    fprintf(stderr,
            "Hadamard scratch does not fit local memory: padded_dim=%u scratch=%u max_per_group=%u total_lmem=%lu\n",
            padded_dim, scratch_bytes, max_localmem, local_mem_size);
    cleanup();
    return -1;
  }

  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, buffer_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, buffer_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_HADAMARD;
  kernel_arg.grid_dim[0] = rows;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  kernel_arg.rows = rows;
  kernel_arg.dim = dim;
  kernel_arg.padded_dim = padded_dim;
  kernel_arg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  printf("Running kernel...\n");
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, buffer_bytes));

  printf("\n[Performance]\n");
  vx_dump_perf(device, stdout);

  int errors = 0;
  float max_diff = 0.0f;
  float mean_diff = 0.0f;
  for (uint32_t i = 0; i < numel; ++i) {
    const float got = fp16_to_float(h_output_gpu[i]);
    const float expected = fp16_to_float(h_output_cpu[i]);
    const float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);
    mean_diff += diff;

    if (diff > 1e-3f) {
      if (errors < 10) {
        printf("Error at flat index %u: GPU=%.6f CPU=%.6f diff=%.6f\n",
               i, got, expected, diff);
      }
      ++errors;
    }
  }
  mean_diff /= static_cast<float>(numel);

  printf("Verification: max_diff=%.6f mean_diff=%.6f errors=%d\n",
         max_diff, mean_diff, errors);

  cleanup();
  if (errors != 0) {
    printf("Hadamard transform failed with %d errors.\n", errors);
    return -1;
  }

  printf("Hadamard transform passed all tests.\n");
  return 0;
}
