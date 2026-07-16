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
vx_buffer_h input_buffer = nullptr;
vx_buffer_h q_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (q_buffer) vx_mem_free(q_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

///////////////////////////////////////////////////////////////////////////////
// CPU Reference Implementation
//
// Matches spinquant_inference/utils/quant_utils.py: quantize_per_token()
// (groupsize == D, i.e. one scale/zero per row).
///////////////////////////////////////////////////////////////////////////////

// Round-half-to-even (banker's rounding), matching torch.round() semantics.
// Mirrors the device kernel's branchless implementation exactly (int<->float
// casts + comparisons only) so host and device agree bit-for-bit; the device
// backend cannot use libm floor/round/fmod inside kernel code (see kernel.cpp).
static float round_half_even(float x) {
  int trunc_i = (int)x;
  float trunc_f = (float)trunc_i;
  int floor_i = trunc_i - (int)(trunc_f > x);
  float floor_x = (float)floor_i;

  float diff = x - floor_x;
  int floor_is_odd = floor_i & 1;
  int round_up = (int)(diff > 0.5f) | ((diff == 0.5f) & floor_is_odd);
  return floor_x + (float)round_up;
}

static int8_t clamp_int4(float q) {
  if (q < -8.0f) q = -8.0f;
  if (q > 7.0f) q = 7.0f;
  return (int8_t)q;
}

void quantize_per_token_cpu(
    const std::vector<data_t>& x,
    std::vector<int8_t>& q,
    std::vector<data_t>& scale,
    std::vector<data_t>& zero,
    uint32_t n_rows,
    uint32_t D,
    uint32_t mode) {
  for (uint32_t r = 0; r < n_rows; ++r) {
    const data_t* row = &x[(uint64_t)r * D];
    int8_t* qrow = &q[(uint64_t)r * D];

    if (mode == QMODE_SYM) {
      float abs_max = 0.0f;
      for (uint32_t i = 0; i < D; ++i) {
        float v = std::fabs(fp16_to_float(row[i]));
        if (v > abs_max) abs_max = v;
      }
      if (abs_max < 1e-8f) abs_max = 1e-8f;
      float S = abs_max / 7.5f;
      scale[r] = float_to_fp16(S);
      zero[r] = float_to_fp16(0.0f);  // unused in sym mode

      for (uint32_t i = 0; i < D; ++i) {
        float v = fp16_to_float(row[i]);
        float qf = round_half_even(v / S);
        qrow[i] = clamp_int4(qf);
      }
    } else {
      float x_min = 1e30f;
      float x_max = -1e30f;
      for (uint32_t i = 0; i < D; ++i) {
        float v = fp16_to_float(row[i]);
        if (v < x_min) x_min = v;
        if (v > x_max) x_max = v;
      }
      float S = (x_max - x_min) / 15.0f;
      if (S < 1e-8f) S = 1e-8f;
      float z = -8.0f - x_min / S;
      scale[r] = float_to_fp16(S);
      zero[r] = float_to_fp16(z);

      for (uint32_t i = 0; i < D; ++i) {
        float v = fp16_to_float(row[i]);
        float qf = round_half_even(v / S + z);
        qrow[i] = clamp_int4(qf);
      }
    }
  }
}

///////////////////////////////////////////////////////////////////////////////
// Helper functions
///////////////////////////////////////////////////////////////////////////////
static void initialize_data(std::vector<data_t>& vec) {
  // Deterministic LCG-based generator spanning both signs and a wide
  // dynamic range, similar in spirit to kv_cache_quant_w4a16's init_src.
  for (size_t i = 0; i < vec.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0x1ffu) - 256;  // [-256, 255]
    float f = float(x) / 32.0f;                              // [-8, 7.97]
    vec[i] = float_to_fp16(f);
  }
}

static bool run_test(vx_device_h device, uint32_t n_rows, uint32_t D, uint32_t mode,
                      uint64_t num_warps, uint64_t num_threads) {
  const char* mode_name = (mode == QMODE_SYM) ? "sym" : "asym";
  printf("\n=== quantize_pt_int4 mode=%s n_rows=%u D=%u ===\n", mode_name, n_rows, D);

  uint32_t elems = n_rows * D;
  std::vector<data_t> h_input(elems);
  std::vector<int8_t> h_q_gpu(elems);
  std::vector<int8_t> h_q_cpu(elems);
  std::vector<data_t> h_scale_gpu(n_rows);
  std::vector<data_t> h_scale_cpu(n_rows);
  std::vector<data_t> h_zero_gpu(n_rows);
  std::vector<data_t> h_zero_cpu(n_rows);

  initialize_data(h_input);

  quantize_per_token_cpu(h_input, h_q_cpu, h_scale_cpu, h_zero_cpu, n_rows, D, mode);

  uint32_t input_bytes = elems * sizeof(data_t);
  uint32_t q_bytes = elems * sizeof(int8_t);
  uint32_t scale_bytes = n_rows * sizeof(data_t);
  uint32_t zero_bytes = n_rows * sizeof(data_t);

  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, q_bytes, VX_MEM_WRITE, &q_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_WRITE, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, zero_bytes, VX_MEM_WRITE, &zero_buffer));

  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, input_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.kernel_id = KERNEL_QUANTIZE_PT_INT4;

  uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
  kernel_arg.grid_dim[0] = n_rows;   // one block per row/token
  kernel_arg.grid_dim[1] = 1;
  kernel_arg.grid_dim[2] = 1;
  kernel_arg.block_dim[0] = threads_per_block;
  kernel_arg.block_dim[1] = 1;
  kernel_arg.block_dim[2] = 1;

  RT_CHECK(vx_mem_address(input_buffer, &kernel_arg.input_addr));
  RT_CHECK(vx_mem_address(q_buffer, &kernel_arg.q_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &kernel_arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &kernel_arg.zero_addr));

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

  RT_CHECK(vx_copy_from_dev(h_q_gpu.data(), q_buffer, 0, q_bytes));
  RT_CHECK(vx_copy_from_dev(h_scale_gpu.data(), scale_buffer, 0, scale_bytes));
  RT_CHECK(vx_copy_from_dev(h_zero_gpu.data(), zero_buffer, 0, zero_bytes));

  vx_dump_perf(device, stdout);

  int q_errors = 0;
  for (uint32_t i = 0; i < elems; ++i) {
    if (h_q_gpu[i] != h_q_cpu[i]) {
      if (q_errors < 10) {
        printf("q mismatch at %u: GPU=%d, CPU=%d\n", i, (int)h_q_gpu[i], (int)h_q_cpu[i]);
      }
      ++q_errors;
    }
  }

  int scale_errors = 0;
  int zero_errors = 0;
  for (uint32_t r = 0; r < n_rows; ++r) {
    if (h_scale_gpu[r] != h_scale_cpu[r]) {
      if (scale_errors < 10) {
        printf("scale mismatch at row %u: GPU=%f, CPU=%f\n", r,
               fp16_to_float(h_scale_gpu[r]), fp16_to_float(h_scale_cpu[r]));
      }
      ++scale_errors;
    }
    if (mode == QMODE_ASYM && h_zero_gpu[r] != h_zero_cpu[r]) {
      if (zero_errors < 10) {
        printf("zero mismatch at row %u: GPU=%f, CPU=%f\n", r,
               fp16_to_float(h_zero_gpu[r]), fp16_to_float(h_zero_cpu[r]));
      }
      ++zero_errors;
    }
  }

  int total_errors = q_errors + scale_errors + zero_errors;
  printf("  q errors: %d, scale errors: %d, zero errors: %d\n",
         q_errors, scale_errors, zero_errors);
  printf(total_errors == 0 ? "PASSED! (mode=%s)\n" : "FAILED! (mode=%s)\n", mode_name);

  vx_mem_free(input_buffer); input_buffer = nullptr;
  vx_mem_free(q_buffer); q_buffer = nullptr;
  vx_mem_free(scale_buffer); scale_buffer = nullptr;
  vx_mem_free(zero_buffer); zero_buffer = nullptr;
  vx_mem_free(krnl_buffer); krnl_buffer = nullptr;
  vx_mem_free(args_buffer); args_buffer = nullptr;

  return (total_errors == 0);
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

  printf("quantize_pt_int4 Test Configuration:\n");
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
    ok &= run_test(device, n_rows, D, QMODE_SYM, num_warps, num_threads);
  }
  if (only_mode == -1 || only_mode == QMODE_ASYM) {
    ok &= run_test(device, n_rows, D, QMODE_ASYM, num_warps, num_threads);
  }

  cleanup();
  return ok ? 0 : -1;
}
