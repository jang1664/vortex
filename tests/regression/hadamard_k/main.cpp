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

// Frees only the per-case I/O + args buffers so the device connection and
// kernel binary stay resident across the multiple test cases below.
static void free_case_buffers() {
  if (input_buffer) { vx_mem_free(input_buffer); input_buffer = nullptr; }
  if (output_buffer) { vx_mem_free(output_buffer); output_buffer = nullptr; }
  if (args_buffer) { vx_mem_free(args_buffer); args_buffer = nullptr; }
}

static bool is_pow2(uint32_t value) {
  return value > 0 && (value & (value - 1)) == 0;
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

// CPU reference for the mixed-radix FWHT butterfly, stopped early at
// stride == stop_stride (mirrors the device kernel's loop exactly).
// Passing stop_stride == padded_dim reproduces the original full-transform
// (K == 1) reference. Passing stop_stride == padded_dim / K reproduces the
// pre-base-matmul intermediate that SpinQuant's hadamard_transform()
// produces right before its `hadK @ input` step (see kernel.cpp for the
// on-device contract). No KxK base matrix is applied here or on device.
static void hadamard_cpu(
    const std::vector<data_t>& input,
    std::vector<data_t>& output,
    uint32_t rows,
    uint32_t dim,
    uint32_t padded_dim,
    uint32_t stop_stride) {
  const float scale = 1.0f / std::sqrt(static_cast<float>(dim));
  std::vector<float> buf(padded_dim);

  for (uint32_t row = 0; row < rows; ++row) {
    const uint32_t row_offset = row * dim;
    for (uint32_t i = 0; i < padded_dim; ++i) {
      buf[i] = (i < dim) ? fp16_to_float(input[row_offset + i]) : 0.0f;
    }

    for (uint32_t stride = 1; stride < stop_stride; stride <<= 1) {
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
  printf("Usage: %s [-rows N] [-seed S] [-k kernel.vxbin]\n", prog);
}

// Runs one FWHT self-test case for a given (dim, K) pair, matching
// SpinQuant's get_hadK(n) contract:
//   K == 1 -> dim must be a pure power of 2; the kernel performs the FULL
//             transform, verified against the unmodified CPU FWHT.
//   K  > 1 -> dim must be a multiple of K with dim/K a power of 2; the
//             kernel STOPS after log2(dim/K) butterfly stages, verified
//             against the CPU butterfly stopped at the same stride (i.e.
//             the intermediate before the KxK base matmul).
// Prints PASS/FAIL and max/mean diff. Returns true on PASS.
static bool run_case(const char* name, uint32_t rows, uint32_t dim, uint32_t K, uint32_t seed) {
  printf("\n=== Case: %s (rows=%u dim=%u K=%u) ===\n", name, rows, dim, K);

  uint32_t padded_dim;
  if (K <= 1) {
    padded_dim = next_power_of_two(dim);
  } else {
    if (dim % K != 0 || !is_pow2(dim / K)) {
      printf("Invalid case config: dim=%u must be a multiple of K=%u with dim/K a power of 2\n", dim, K);
      return false;
    }
    // Mixed-radix case: dim/K is already a power of 2, so no zero-padding is
    // needed (or allowed) -- padding would corrupt the K-block structure
    // that the host-side base matmul expects.
    padded_dim = dim;
  }
  const uint32_t stop_stride = padded_dim / K;

  const uint32_t numel = rows * dim;
  const uint64_t buffer_bytes = static_cast<uint64_t>(numel) * sizeof(data_t);

  printf("  Padded Dim:  %u\n", padded_dim);
  printf("  Stop Stride: %u\n", stop_stride);

  std::vector<data_t> h_input(numel);
  std::vector<data_t> h_output_gpu(numel);
  std::vector<data_t> h_output_cpu(numel);

  srand(seed);
  initialize_random(h_input);
  hadamard_cpu(h_input, h_output_cpu, rows, dim, padded_dim, stop_stride);

  uint64_t num_warps, num_threads, local_mem_size;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));

  const uint32_t threads_per_block = std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
  uint32_t max_localmem = 0;
  RT_CHECK(vx_check_occupancy(device, threads_per_block, &max_localmem));
  const uint32_t scratch_bytes = padded_dim * sizeof(float);
  if (scratch_bytes > max_localmem) {
    fprintf(stderr,
            "Hadamard scratch does not fit local memory: padded_dim=%u scratch=%u max_per_group=%u total_lmem=%lu\n",
            padded_dim, scratch_bytes, max_localmem, local_mem_size);
    return false;
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
  kernel_arg.stop_stride = stop_stride;
  kernel_arg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

  printf("Running kernel...\n");
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, buffer_bytes));

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

  free_case_buffers();

  if (errors != 0) {
    printf("[%s] FAIL (%d errors)\n", name, errors);
    return false;
  }
  printf("[%s] PASS\n", name);
  return true;
}

int main(int argc, char *argv[]) {
  uint32_t rows = 4;
  uint32_t seed = 42;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-rows") == 0 && i + 1 < argc) {
      rows = static_cast<uint32_t>(atoi(argv[++i]));
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

  if (rows == 0) {
    fprintf(stderr, "Invalid shape: rows=%u\n", rows);
    return -1;
  }

  printf("Hadamard-K Test Configuration:\n");
  printf("  Rows: %u\n", rows);
  printf("  Seed: %u\n", seed);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  bool pass = true;

  // Case (a): K == 1, dim a pure power of 2 -> full transform. Must match
  // the original (non-early-stop) kernel's behavior exactly.
  pass &= run_case("K1_pow2_full_transform", rows, /*dim=*/64, /*K=*/1, seed);

  // Case (b): small analog of LLaMA-2-7B's n=11008,K=172 (11008/172=64 is a
  // power of 2): dim=24, K=3, dim/K=8 is a power of 2. Validates the
  // early-stop logic against the CPU butterfly stopped at K -- i.e. the
  // pre-base-matmul intermediate -- without needing the real 172x172 (or a
  // 3x3) base matrix.
  pass &= run_case("K3_early_stop_pre_basematmul", rows, /*dim=*/24, /*K=*/3, seed);

  printf("\n[Performance]\n");
  vx_dump_perf(device, stdout);

  cleanup();

  if (!pass) {
    printf("\nHadamard-K self-test: OVERALL FAIL\n");
    return -1;
  }
  printf("\nHadamard-K self-test: OVERALL PASS\n");
  return 0;
}
