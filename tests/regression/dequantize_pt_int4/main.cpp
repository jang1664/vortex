#include <iostream>
#include <cstdio>
#include <vector>
#include <cmath>
#include <cstring>
#include <cstdlib>
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
vx_buffer_h q_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (q_buffer) vx_mem_free(q_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
//
// Matches spinquant_inference/utils/quant_utils.py: dequantize_per_token()
// with groupsize == D (one scale/zero per row).
//   sym:  x_i = scale * q_i
//   asym: x_i = scale * (q_i - zero)
///////////////////////////////////////////////////////////////////////////////
void dequantize_per_token_cpu(
    const std::vector<int8_t>& q,
    const std::vector<data_t>& scale,
    const std::vector<data_t>& zero,
    std::vector<data_t>& output,
    uint32_t n_rows,
    uint32_t D,
    uint32_t mode) {
  for (uint32_t r = 0; r < n_rows; ++r) {
    const float s = fp16_to_float(scale[r]);
    const int8_t* qrow = &q[(uint64_t)r * D];
    data_t* orow = &output[(uint64_t)r * D];

    if (mode == QMODE_SYM) {
      for (uint32_t i = 0; i < D; ++i) {
        float x = s * (float)qrow[i];
        orow[i] = float_to_fp16(x);
      }
    } else {
      const float z = fp16_to_float(zero[r]);
      for (uint32_t i = 0; i < D; ++i) {
        float x = s * ((float)qrow[i] - z);
        orow[i] = float_to_fp16(x);
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
static void initialize_q(std::vector<int8_t>& q) {
  // Deterministic LCG-based generator covering the full signed int4
  // range [-8, 7].
  for (size_t i = 0; i < q.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0x0fu) - 8;  // [-8, 7]
    q[i] = (int8_t)x;
  }
}

static void initialize_scale_zero(std::vector<data_t>& scale, std::vector<data_t>& zero) {
  for (size_t r = 0; r < scale.size(); ++r) {
    int sx = int((r * 2654435761u + 1u) & 0xffu);       // [0, 255]
    float s = 0.01f + float(sx) / 512.0f;                // small positive scale
    scale[r] = float_to_fp16(s);

    int zx = int((r * 40503u + 7u) & 0xffu) - 128;       // [-128, 127]
    float z = float(zx) / 16.0f;                         // wide zero-point range
    zero[r] = float_to_fp16(z);
  }
}

int float_compare(float got, float expected) {
  float diff = std::fabs(got - expected);
  float abs_threshold = 1e-3f;
  float rel_threshold = std::fabs(expected) * 1e-2f;  // 1% relative error, per task spec
  float threshold = std::max(abs_threshold, rel_threshold);
  return diff <= threshold;
}

static bool run_test(vx_device_h device, uint32_t n_rows, uint32_t D, uint32_t mode,
                      uint64_t num_warps, uint64_t num_threads, uint64_t num_cores) {
  const char* mode_name = (mode == QMODE_SYM) ? "sym" : "asym";
  printf("\n=== dequantize_pt_int4 mode=%s n_rows=%u D=%u ===\n", mode_name, n_rows, D);

  uint32_t elems = n_rows * D;
  std::vector<int8_t> h_q(elems);
  std::vector<data_t> h_scale(n_rows);
  std::vector<data_t> h_zero(n_rows);
  std::vector<data_t> h_output_gpu(elems);
  std::vector<data_t> h_output_cpu(elems);

  initialize_q(h_q);
  initialize_scale_zero(h_scale, h_zero);

  dequantize_per_token_cpu(h_q, h_scale, h_zero, h_output_cpu, n_rows, D, mode);

  uint32_t q_bytes = elems * sizeof(int8_t);
  uint32_t scale_bytes = n_rows * sizeof(data_t);
  uint32_t zero_bytes = n_rows * sizeof(data_t);
  uint32_t output_bytes = elems * sizeof(data_t);

  RT_CHECK(vx_mem_alloc(device, q_bytes, VX_MEM_READ, &q_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_READ, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, zero_bytes, VX_MEM_READ, &zero_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));

  RT_CHECK(vx_copy_to_dev(q_buffer, h_q.data(), 0, q_bytes));
  RT_CHECK(vx_copy_to_dev(scale_buffer, h_scale.data(), 0, scale_bytes));
  RT_CHECK(vx_copy_to_dev(zero_buffer, h_zero.data(), 0, zero_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_DEQUANTIZE_PT_INT4;

  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t blocks = std::min(
      (uint32_t)((elems + threads_per_block - 1) / threads_per_block),
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg.grid_dim[0] = blocks;
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  RT_CHECK(vx_mem_address(q_buffer, &kernel_arg.q_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &kernel_arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &kernel_arg.zero_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));

  kernel_arg.n_rows = n_rows;
  kernel_arg.D = D;
  kernel_arg.mode = mode;

  printf("Grid: [%d, %d, %d]  Block: [%d, %d, %d]\n",
         kernel_arg.grid_dim[0], kernel_arg.grid_dim[1], kernel_arg.grid_dim[2],
         kernel_arg.block_dim[0], kernel_arg.block_dim[1], kernel_arg.block_dim[2]);

  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  RT_CHECK(vx_copy_from_dev(h_output_gpu.data(), output_buffer, 0, output_bytes));

  vx_dump_perf(device, stdout);

  int errors = 0;
  float max_diff = 0.0f;
  float max_rel_error = 0.0f;
  for (uint32_t i = 0; i < elems; ++i) {
    float got = fp16_to_float(h_output_gpu[i]);
    float expected = fp16_to_float(h_output_cpu[i]);
    float diff = std::fabs(got - expected);
    max_diff = std::max(max_diff, diff);

    if (!float_compare(got, expected)) {
      float rel_error = (expected != 0.0f) ? diff / std::fabs(expected) : 0.0f;
      max_rel_error = std::max(max_rel_error, rel_error);
      if (errors < 10) {
        printf("Error at %u: GPU=%.6f, CPU=%.6f, diff=%.6f, rel_err=%.2f%%\n",
               i, got, expected, diff, rel_error * 100.0f);
      }
      ++errors;
    }
  }

  printf("  Max absolute diff: %.6f\n", max_diff);
  printf("  Max relative error: %.2f%%\n", max_rel_error * 100.0f);
  printf(errors == 0 ? "PASSED! (mode=%s)\n" : "FAILED! (mode=%s)\n", mode_name);

  vx_mem_free(q_buffer); q_buffer = nullptr;
  vx_mem_free(scale_buffer); scale_buffer = nullptr;
  vx_mem_free(zero_buffer); zero_buffer = nullptr;
  vx_mem_free(output_buffer); output_buffer = nullptr;
  vx_mem_free(krnl_buffer); krnl_buffer = nullptr;
  vx_mem_free(args_buffer); args_buffer = nullptr;

  return (errors == 0);
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[]) {
  uint32_t n_rows = 17;   // deliberately not a power of 2
  uint32_t D = 128;
  int only_mode = -1;     // -1 = test both sym and asym

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-rows") == 0) {
      n_rows = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-dim") == 0) {
      D = atoi(argv[++i]);
    } else if (strcmp(argv[i], "-mode") == 0) {
      const char* m = argv[++i];
      if (strcmp(m, "sym") == 0) only_mode = QMODE_SYM;
      else if (strcmp(m, "asym") == 0) only_mode = QMODE_ASYM;
      else { printf("Unknown mode '%s'\n", m); return -1; }
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-rows N] [-dim D] [-mode sym|asym]\n", argv[0]);
      return 0;
    }
  }

  printf("dequantize_pt_int4 Test Configuration:\n");
  printf("  Rows (tokens): %u\n", n_rows);
  printf("  Dim (D):       %u\n", D);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  printf("Device Caps: cores=%ld, warps=%ld, threads=%ld\n",
         num_cores, num_warps, num_threads);

  bool ok = true;
  if (only_mode == -1 || only_mode == QMODE_SYM) {
    ok &= run_test(device, n_rows, D, QMODE_SYM, num_warps, num_threads, num_cores);
  }
  if (only_mode == -1 || only_mode == QMODE_ASYM) {
    ok &= run_test(device, n_rows, D, QMODE_ASYM, num_warps, num_threads, num_cores);
  }

  cleanup();
  return ok ? 0 : -1;
}
