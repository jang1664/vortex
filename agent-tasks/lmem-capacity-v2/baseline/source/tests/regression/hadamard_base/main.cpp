#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include <vortex.h>

#include "../vector_common/fp16.h"
#include "common.h"

using data_t = fp16_t;

#ifndef HADAMARD_BASE_VARIANT_TAG
#define HADAMARD_BASE_VARIANT_TAG 0
#endif

#define RT_CHECK(expr) \
  do {                 \
    if ((expr) != 0)   \
      return 1;        \
  } while (false)

int main() {
  constexpr uint32_t rows = 2;
  constexpr uint32_t base_k = 3;
  constexpr uint32_t width = 8;
  constexpr uint32_t total = rows * base_k * width;
  std::vector<data_t> input(total);
  std::vector<data_t> matrix(base_k * base_k);
  std::vector<data_t> output(total);
  std::vector<float> reference(total);
  for (uint32_t i = 0; i < total; ++i)
    input[i] = float_to_fp16((static_cast<int>(i % 13) - 6) / 8.0f);
  const float coefficients[9] = {1, 1, 1, 1, -1, 1, 1, 1, -1};
  for (uint32_t i = 0; i < 9; ++i)
    matrix[i] = float_to_fp16(coefficients[i]);
  for (uint32_t row = 0; row < rows; ++row) {
    for (uint32_t out_k = 0; out_k < base_k; ++out_k) {
      for (uint32_t col = 0; col < width; ++col) {
        float sum = 0;
        for (uint32_t in_k = 0; in_k < base_k; ++in_k) {
          sum += coefficients[out_k * base_k + in_k] * fp16_to_float(input[(row * base_k + in_k) * width + col]);
        }
        reference[(row * base_k + out_k) * width + col] = sum;
      }
    }
  }

  vx_device_h device = nullptr;
  vx_buffer_h kernel = nullptr, args = nullptr, in = nullptr, mat = nullptr, out = nullptr;
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel));
  RT_CHECK(vx_mem_alloc(device, total * sizeof(data_t), VX_MEM_READ, &in));
  RT_CHECK(vx_mem_alloc(device, matrix.size() * sizeof(data_t), VX_MEM_READ, &mat));
  RT_CHECK(vx_mem_alloc(device, total * sizeof(data_t), VX_MEM_WRITE, &out));
  RT_CHECK(vx_copy_to_dev(in, input.data(), 0, total * sizeof(data_t)));
  RT_CHECK(vx_copy_to_dev(mat, matrix.data(), 0, matrix.size() * sizeof(data_t)));
  uint64_t warps = 0, threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &threads));
  const uint32_t block = std::min<uint32_t>(256, warps * threads);
  kernel_arg_t karg{};
  karg.kernel_id = KERNEL_HADAMARD_BASE;
#if HADAMARD_BASE_VARIANT_TAG == 1
  karg.grid_dim[0] = (rows * width + block - 1) / block;
#else
  karg.grid_dim[0] = (total + block - 1) / block;
#endif
  karg.grid_dim[1] = karg.grid_dim[2] = 1;
  karg.block_dim[0] = block;
  karg.block_dim[1] = karg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(in, &karg.input_addr));
  RT_CHECK(vx_mem_address(mat, &karg.matrix_addr));
  RT_CHECK(vx_mem_address(out, &karg.output_addr));
  karg.rows = rows;
  karg.base_k = base_k;
  karg.width = width;
  RT_CHECK(vx_upload_bytes(device, &karg, sizeof(karg), &args));
  RT_CHECK(vx_start(device, kernel, args));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(output.data(), out, 0, total * sizeof(data_t)));
  int errors = 0;
  for (uint32_t i = 0; i < total; ++i)
    errors += std::abs(fp16_to_float(output[i]) - reference[i]) > 1e-3f;
  std::printf("hadamard_base: %s (%d errors)\n", errors ? "FAIL" : "PASS", errors);
  vx_mem_free(out);
  vx_mem_free(mat);
  vx_mem_free(in);
  vx_mem_free(args);
  vx_mem_free(kernel);
  vx_dev_close(device);
  return errors ? 1 : 0;
}
