#include "../vector_common/fp16.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "common.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

static uint32_t log2_u32(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) < value) ++result;
  return result;
}

int main(int argc, char** argv) {
  constexpr uint32_t M = 4;
  constexpr uint32_t N = 32;
  constexpr uint32_t D = 32;
  uint32_t layout_mode = QK_SCORES_LAYOUT_ROW_MAJOR;
  uint32_t query_layout = QK_QUERY_LAYOUT_ROW_MAJOR;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--layout") == 0) {
      if (++i >= argc) {
        std::fprintf(stderr, "--layout requires row_major or gemm_c_tiled\n");
        return 2;
      }
      if (strcmp(argv[i], "row_major") == 0) {
        layout_mode = QK_SCORES_LAYOUT_ROW_MAJOR;
      } else if (strcmp(argv[i], "gemm_c_tiled") == 0) {
        layout_mode = QK_SCORES_LAYOUT_GEMM_C_TILED;
      } else {
        std::fprintf(stderr, "invalid --layout value: %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--query-layout") == 0) {
      if (++i >= argc) {
        std::fprintf(stderr, "--query-layout requires row_major or gemm_a_tiled\n");
        return 2;
      }
      if (strcmp(argv[i], "row_major") == 0) {
        query_layout = QK_QUERY_LAYOUT_ROW_MAJOR;
      } else if (strcmp(argv[i], "gemm_a_tiled") == 0) {
        query_layout = QK_QUERY_LAYOUT_GEMM_A_TILED;
      } else {
        std::fprintf(stderr, "invalid --query-layout value: %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      std::printf(
          "Usage: %s [--layout row_major|gemm_c_tiled] "
          "[--query-layout row_major|gemm_a_tiled]\n",
          argv[0]);
      return 0;
    }
  }
  const uint32_t scores_m_pad = (M + 7u) & ~7u;
  const size_t physical_score_elems = layout_mode == QK_SCORES_LAYOUT_GEMM_C_TILED
      ? size_t(scores_m_pad) * N : size_t(M) * N;
  const size_t physical_query_elems = query_layout == QK_QUERY_LAYOUT_GEMM_A_TILED
      ? size_t(scores_m_pad) * D : size_t(M) * D;
  std::vector<data_t> scores_row(M * N), scores(physical_score_elems, 0);
  std::vector<data_t> query_row(M * D), query(physical_query_elems, 0);
  std::vector<data_t> scale(N), zero(N), output(physical_score_elems);
  std::vector<float> reference(M * N);
  for (uint32_t i = 0; i < M * N; ++i)
    scores_row[i] = float_to_fp16((int(i % 13) - 6) / 8.0f);
  for (uint32_t row = 0; row < M; ++row) {
    for (uint32_t column = 0; column < N; ++column) {
      const uint64_t physical = layout_mode == QK_SCORES_LAYOUT_GEMM_C_TILED
          ? gemm_c_tiled_elem_offset(row, column, scores_m_pad, N,
                                     log2_u32(QK_TILE_DMA_MT),
                                     log2_u32(QK_TILE_MXU_NT))
          : (uint64_t)row * N + column;
      scores[physical] = scores_row[(uint64_t)row * N + column];
    }
  }
  for (uint32_t i = 0; i < M * D; ++i)
    query_row[i] = float_to_fp16((int(i % 11) - 5) / 7.0f);
  for (uint32_t row = 0; row < M; ++row) {
    for (uint32_t column = 0; column < D; ++column) {
      const uint64_t physical = query_layout == QK_QUERY_LAYOUT_GEMM_A_TILED
          ? gemm_a_tiled_elem_offset(row, column, scores_m_pad, D,
                                     log2_u32(QK_TILE_DMA_MT),
                                     log2_u32(QK_TILE_MXU_NT))
          : (uint64_t)row * D + column;
      query[physical] = query_row[(uint64_t)row * D + column];
    }
  }
  for (uint32_t i = 0; i < N; ++i) {
    scale[i] = float_to_fp16(0.02f * (i + 1));
    zero[i] = float_to_fp16(-1.5f + 0.25f * i);
  }
  for (uint32_t row = 0; row < M; ++row) {
    float query_sum = 0.0f;
    for (uint32_t d = 0; d < D; ++d)
      query_sum += fp16_to_float(query_row[row * D + d]);
    for (uint32_t column = 0; column < N; ++column) {
      reference[row * N + column] = fp16_to_float(scores_row[row * N + column]) - query_sum * fp16_to_float(scale[column]) * fp16_to_float(zero[column]);
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
  arg.scores_layout = layout_mode;
  arg.query_layout = query_layout;
  arg.scores_m_pad = scores_m_pad;
  arg.log2_mt = log2_u32(QK_TILE_DMA_MT);
  arg.log2_mxu_nt = log2_u32(QK_TILE_MXU_NT);
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(output.data(), output_buffer, 0, output.size() * sizeof(data_t)));

  int errors = 0;
  for (uint32_t i = 0; i < M * N; ++i) {
    const uint32_t row = i / N;
    const uint32_t column = i - row * N;
    const uint64_t physical = layout_mode == QK_SCORES_LAYOUT_GEMM_C_TILED
        ? gemm_c_tiled_elem_offset(row, column, scores_m_pad, N,
                                   arg.log2_mt, arg.log2_mxu_nt)
        : i;
    const float actual = fp16_to_float(output[physical]);
    if (std::fabs(actual - reference[i]) > 0.002f)
      ++errors;
  }
  cleanup();
  std::printf(errors ? "FAILED! errors=%d\n" : "PASSED!\n", errors);
  return errors ? 1 : 0;
}
