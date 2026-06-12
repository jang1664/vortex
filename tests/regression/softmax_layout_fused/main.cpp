#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vortex.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = fp16_t;

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h input_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;

#define RT_CHECK(_expr)                                                     \
  do {                                                                      \
    int _ret = _expr;                                                       \
    if (0 == _ret)                                                          \
      break;                                                                \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);                \
    cleanup();                                                              \
    exit(-1);                                                               \
  } while (false)

static void cleanup() {
  if (input_buffer) vx_mem_free(input_buffer);
  if (output_buffer) vx_mem_free(output_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static bool is_pow2(uint32_t v) {
  return v && ((v & (v - 1u)) == 0);
}

static uint32_t log2_u32(uint32_t v) {
  uint32_t r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

static uint32_t align_up(uint32_t a, uint32_t b) {
  return ((a + b - 1) / b) * b;
}

static void init_scores(std::vector<data_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 22695477u + 1u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 64.0f);
  }
}

static size_t row_index(uint32_t b, uint32_t h, uint32_t q, uint32_t k,
                        uint32_t heads, uint32_t seq_q, uint32_t seq_k) {
  return (((size_t)b * heads + h) * seq_q + q) * seq_k + k;
}

static void pack_scores(const std::vector<data_t>& row,
                        std::vector<data_t>& tiled,
                        uint32_t batch,
                        uint32_t heads,
                        uint32_t seq_q,
                        uint32_t seq_k,
                        uint32_t seq_k_pad,
                        uint32_t M_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint64_t matrix_elems = (uint64_t)M_pad * seq_k_pad;
  std::fill(tiled.begin(), tiled.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t h = 0; h < heads; ++h) {
      const uint32_t matrix = b * heads + h;
      const uint64_t base = batched_matrix_base(matrix, matrix_elems);
      for (uint32_t q = 0; q < seq_q; ++q) {
        for (uint32_t k = 0; k < seq_k; ++k) {
          const uint64_t off = base + gemm_c_tiled_elem_offset(
              q, k, M_pad, seq_k_pad, log2_mt, log2_mxu_nt);
          tiled[off] = row[row_index(b, h, q, k, heads, seq_q, seq_k)];
        }
      }
    }
  }
}

static void softmax_reference(const std::vector<data_t>& input,
                              std::vector<data_t>& ref_tiled,
                              uint32_t batch,
                              uint32_t heads,
                              uint32_t seq_q,
                              uint32_t seq_k,
                              uint32_t seq_k_pad,
                              uint32_t M_pad,
                              bool use_mask,
                              float scale) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  const uint64_t matrix_elems = (uint64_t)M_pad * seq_k_pad;
  std::fill(ref_tiled.begin(), ref_tiled.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t h = 0; h < heads; ++h) {
      const uint32_t matrix = b * heads + h;
      const uint64_t base = batched_matrix_base(matrix, matrix_elems);
      for (uint32_t q = 0; q < seq_q; ++q) {
        float max_v = -INFINITY;
        for (uint32_t k = 0; k < seq_k; ++k) {
          float v = fp16_to_float(input[row_index(b, h, q, k, heads, seq_q, seq_k)]) * scale;
          if (use_mask && k > q) v = -INFINITY;
          max_v = std::max(max_v, v);
        }
        float sum = 0.0f;
        for (uint32_t k = 0; k < seq_k; ++k) {
          float v = fp16_to_float(input[row_index(b, h, q, k, heads, seq_q, seq_k)]) * scale;
          if (use_mask && k > q) v = -INFINITY;
          sum += std::exp(v - max_v);
        }
        for (uint32_t k = 0; k < seq_k; ++k) {
          float v = fp16_to_float(input[row_index(b, h, q, k, heads, seq_q, seq_k)]) * scale;
          if (use_mask && k > q) v = -INFINITY;
          const uint64_t off = base + gemm_a_tiled_elem_offset(
              q, k, M_pad, seq_k_pad, log2_mt, log2_mxu_kt);
          ref_tiled[off] = float_to_fp16(std::exp(v - max_v) / sum);
        }
      }
    }
  }
}

int main(int argc, char *argv[]) {
  uint32_t batch = 1;
  uint32_t heads = 1;
  uint32_t seq_q = 4;
  uint32_t seq_k = 32;
  uint32_t use_mask = 1;
  float scale = 1.0f;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqq") == 0) seq_q = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seqk") == 0) seq_k = atoi(argv[++i]);
    else if (strcmp(argv[i], "-mask") == 0) use_mask = atoi(argv[++i]);
    else if (strcmp(argv[i], "-scale") == 0) scale = atof(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch B] [-heads H] [-seqq Q] [-seqk K] [-mask 0|1] [-scale S]\n", argv[0]);
      return 0;
    }
  }

  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) ||
      !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  const uint32_t M_pad = (seq_q + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t seq_k_pad = align_up(seq_k, std::max(TILE_DMA_MXU_KT, TILE_DMA_MXU_NT));
  printf("softmax_layout_fused batch=%u heads=%u seqq=%u seqk=%u seqk_pad=%u M_pad=%u mask=%u scale=%f\n",
         batch, heads, seq_q, seq_k, seq_k_pad, M_pad, use_mask, scale);

  const size_t row_elems = (size_t)batch * heads * seq_q * seq_k;
  const size_t tiled_elems = (size_t)batch * heads * M_pad * seq_k_pad;
  const size_t tiled_bytes = tiled_elems * sizeof(data_t);
  std::vector<data_t> h_input_row(row_elems);
  std::vector<data_t> h_input_tiled(tiled_elems);
  std::vector<data_t> h_ref(tiled_elems);
  std::vector<data_t> h_out(tiled_elems, 0);
  init_scores(h_input_row);
  pack_scores(h_input_row, h_input_tiled, batch, heads, seq_q, seq_k, seq_k_pad, M_pad);
  softmax_reference(h_input_row, h_ref, batch, heads, seq_q, seq_k, seq_k_pad, M_pad, use_mask != 0, scale);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, tiled_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input_tiled.data(), 0, tiled_bytes));

  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  // One warp (= num_threads lanes) per block, so each row occupies a single
  // warp and up to num_warps rows are co-resident on a core. While one row's
  // lane 0 busy-waits on its DMA descriptor, the other resident rows keep
  // computing, hiding the DMA issue/poll latency that otherwise stalls the
  // whole core when a block spans all warps.
  const uint32_t tpb = std::min(256u, (uint32_t)num_threads);

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_SOFTMAX_LAYOUT_FUSED;
  arg.grid_dim[0] = batch * heads * seq_q;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.batch_size = batch;
  arg.num_heads = heads;
  arg.seq_len_q = seq_q;
  arg.seq_len_k = seq_k;
  arg.seq_len_k_pad = seq_k_pad;
  arg.M_pad = M_pad;
  arg.use_mask = use_mask;
  arg.scale = scale;
  arg.log2_mt = log2_u32(TILE_DMA_MT);
  arg.log2_kt = log2_u32(TILE_DMA_KT);
  arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, tiled_bytes));

  int errors = 0;
  float max_diff = 0.0f;
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t h = 0; h < heads; ++h) {
      const uint64_t base = batched_matrix_base(b * heads + h, (uint64_t)M_pad * seq_k_pad);
      for (uint32_t q = 0; q < seq_q; ++q) {
        for (uint32_t k = 0; k < seq_k; ++k) {
          const uint64_t off = base + gemm_a_tiled_elem_offset(
              q, k, M_pad, seq_k_pad, arg.log2_mt, arg.log2_mxu_kt);
          const float got = fp16_to_float(h_out[off]);
          const float expected = fp16_to_float(h_ref[off]);
          const float diff = std::abs(got - expected);
          max_diff = std::max(max_diff, diff);
          if (diff > 1e-4f) {
            if (errors < 10) {
              printf("Error at b=%u h=%u q=%u k=%u: got=%f expected=%f diff=%f\n",
                     b, h, q, k, got, expected, diff);
            }
            ++errors;
          }
        }
      }
    }
  }

  printf("max_diff=%f errors=%d\n", max_diff, errors);
  vx_dump_perf(device, stdout);
  cleanup();
  if (errors == 0) {
    printf("PASSED!\n");
    return 0;
  }
  printf("FAILED!\n");
  return 1;
}
