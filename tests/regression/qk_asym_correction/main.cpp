#include "../vector_common/fp16.h"
#include "common.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>
#include <vortex.h>

using data_t = fp16_t;

static vx_device_h device = nullptr;
static vx_buffer_h kernel_buffer = nullptr;
static vx_buffer_h args_buffer = nullptr;
static vx_buffer_h scores_buffer = nullptr;
static vx_buffer_h query_buffer = nullptr;
static vx_buffer_h scale_buffer = nullptr;
static vx_buffer_h zero_buffer = nullptr;
static vx_buffer_h output_buffer = nullptr;

static void cleanup() {
  if (scores_buffer)
    vx_mem_free(scores_buffer);
  if (query_buffer)
    vx_mem_free(query_buffer);
  if (scale_buffer)
    vx_mem_free(scale_buffer);
  if (zero_buffer)
    vx_mem_free(zero_buffer);
  if (output_buffer)
    vx_mem_free(output_buffer);
  if (kernel_buffer)
    vx_mem_free(kernel_buffer);
  if (args_buffer)
    vx_mem_free(args_buffer);
  if (device)
    vx_dev_close(device);
}

#define RT_CHECK(expr)                                    \
  do {                                                    \
    int ret = (expr);                                     \
    if (ret != 0) {                                       \
      std::printf("Error: %s returned %d\n", #expr, ret); \
      cleanup();                                          \
      return 1;                                           \
    }                                                     \
  } while (0)

int main() {
  constexpr uint32_t M = 4;
  constexpr uint32_t N = 8;
  constexpr uint32_t D = 16;
  std::vector<data_t> scores(M * N), query(M * D), scale(N), zero(N), output(M * N);
  std::vector<float> reference(M * N);
  for (uint32_t i = 0; i < M * N; ++i)
    scores[i] = float_to_fp16((int(i % 13) - 6) / 8.0f);
  for (uint32_t i = 0; i < M * D; ++i)
    query[i] = float_to_fp16((int(i % 11) - 5) / 7.0f);
  for (uint32_t i = 0; i < N; ++i) {
    scale[i] = float_to_fp16(0.02f * (i + 1));
    zero[i] = float_to_fp16(-1.5f + 0.25f * i);
  }
  for (uint32_t row = 0; row < M; ++row) {
    float query_sum = 0.0f;
    for (uint32_t d = 0; d < D; ++d)
      query_sum += fp16_to_float(query[row * D + d]);
    for (uint32_t column = 0; column < N; ++column) {
      reference[row * N + column] = fp16_to_float(scores[row * N + column]) - query_sum * fp16_to_float(scale[column]) * fp16_to_float(zero[column]);
    }
  }

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_mem_alloc(device, scores.size() * sizeof(data_t), VX_MEM_READ, &scores_buffer));
  RT_CHECK(vx_mem_alloc(device, query.size() * sizeof(data_t), VX_MEM_READ, &query_buffer));
  RT_CHECK(vx_mem_alloc(device, scale.size() * sizeof(data_t), VX_MEM_READ, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, zero.size() * sizeof(data_t), VX_MEM_READ, &zero_buffer));
  RT_CHECK(vx_mem_alloc(device, output.size() * sizeof(data_t), VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(scores_buffer, scores.data(), 0, scores.size() * sizeof(data_t)));
  RT_CHECK(vx_copy_to_dev(query_buffer, query.data(), 0, query.size() * sizeof(data_t)));
  RT_CHECK(vx_copy_to_dev(scale_buffer, scale.data(), 0, scale.size() * sizeof(data_t)));
  RT_CHECK(vx_copy_to_dev(zero_buffer, zero.data(), 0, zero.size() * sizeof(data_t)));

  uint64_t warps = 0, threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &threads));
  kernel_arg_t arg{};
  arg.kernel_id = KERNEL_QK_ASYM_CORRECTION;
  arg.grid_dim[0] = M;
  arg.block_dim[0] = std::min<uint32_t>(256, warps * threads);
  arg.block_dim[1] = arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(scores_buffer, &arg.scores_addr));
  RT_CHECK(vx_mem_address(query_buffer, &arg.query_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.M = M;
  arg.N = N;
  arg.D = D;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(output.data(), output_buffer, 0, output.size() * sizeof(data_t)));

  int errors = 0;
  for (uint32_t i = 0; i < M * N; ++i) {
    const float actual = fp16_to_float(output[i]);
    if (std::fabs(actual - reference[i]) > 0.002f)
      ++errors;
  }
  cleanup();
  std::printf(errors ? "FAILED! errors=%d\n" : "PASSED!\n", errors);
  return errors ? 1 : 0;
}
