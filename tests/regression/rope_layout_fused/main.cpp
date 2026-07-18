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
vx_buffer_h cos_buffer = nullptr;
vx_buffer_h sin_buffer = nullptr;

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
  if (cos_buffer) vx_mem_free(cos_buffer);
  if (sin_buffer) vx_mem_free(sin_buffer);
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

static uint32_t parse_layout_to(const char* value) {
  if (strcmp(value, "gemm_a_tiled") == 0 || strcmp(value, "a") == 0) {
    return ROPE_LAYOUT_TO_GEMM_A;
  }
  if (strcmp(value, "gemm_w_tiled") == 0 || strcmp(value, "w") == 0) {
    return ROPE_LAYOUT_TO_GEMM_W;
  }
  if (strcmp(value, "row_major") == 0 || strcmp(value, "row") == 0) {
    return ROPE_LAYOUT_TO_ROW_MAJOR;
  }
  if (strcmp(value, "head_major_row") == 0 || strcmp(value, "bhsd") == 0) {
    return ROPE_LAYOUT_TO_HEAD_MAJOR_ROW;
  }
  printf("ERROR: --layout-to must be gemm_a_tiled, gemm_w_tiled, row_major, or head_major_row\n");
  exit(1);
}

static const char* layout_to_name(uint32_t layout_to) {
  if (layout_to == ROPE_LAYOUT_TO_GEMM_A) return "gemm_a_tiled";
  if (layout_to == ROPE_LAYOUT_TO_GEMM_W) return "gemm_w_tiled";
  if (layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW) return "head_major_row";
  return "row_major";
}

static size_t row_index(uint32_t b, uint32_t s, uint32_t h, uint32_t d,
                        uint32_t seq, uint32_t heads, uint32_t head_dim) {
  return (((size_t)b * seq + s) * heads + h) * head_dim + d;
}

static size_t head_major_row_index(uint32_t b, uint32_t s, uint32_t h, uint32_t d,
                                   uint32_t seq, uint32_t heads, uint32_t head_dim) {
  return (((size_t)b * heads + h) * seq + s) * head_dim + d;
}

static void init_input(std::vector<data_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 80.0f);
  }
}

static void precompute_freqs(std::vector<data_t>& cos_table,
                             std::vector<data_t>& sin_table,
                             uint32_t max_seq_len,
                             uint32_t head_dim) {
  const uint32_t half_dim = head_dim >> 1;
  cos_table.resize((size_t)max_seq_len * half_dim);
  sin_table.resize((size_t)max_seq_len * half_dim);
  for (uint32_t pos = 0; pos < max_seq_len; ++pos) {
    for (uint32_t p = 0; p < half_dim; ++p) {
      float freq = std::pow(10000.0f, -2.0f * float(p) / float(head_dim));
      float theta = float(pos) * freq;
      cos_table[(size_t)pos * half_dim + p] = float_to_fp16(std::cos(theta));
      sin_table[(size_t)pos * half_dim + p] = float_to_fp16(std::sin(theta));
    }
  }
}

static void pack_projection(const std::vector<data_t>& row,
                            std::vector<data_t>& tiled,
                            uint32_t batch,
                            uint32_t seq,
                            uint32_t heads,
                            uint32_t head_dim,
                            uint32_t input_m_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint32_t input_n = heads * head_dim;
  std::fill(tiled.begin(), tiled.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      const uint32_t m = b * seq + s;
      for (uint32_t h = 0; h < heads; ++h) {
        for (uint32_t d = 0; d < head_dim; ++d) {
          const uint32_t n = h * head_dim + d;
          const uint64_t off = gemm_c_tiled_elem_offset(
              m, n, input_m_pad, input_n, log2_mt, log2_mxu_nt);
          tiled[off] = row[row_index(b, s, h, d, seq, heads, head_dim)];
        }
      }
    }
  }
}

static void build_reference(const std::vector<data_t>& input,
                            const std::vector<data_t>& cos_table,
                            const std::vector<data_t>& sin_table,
                            std::vector<data_t>& ref,
                            uint32_t batch,
                            uint32_t seq,
                            uint32_t heads,
                            uint32_t head_dim,
                            uint32_t max_seq,
                            uint32_t pos_offset,
                            uint32_t output_m_pad,
                            uint32_t layout_to) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_kt = log2_u32(TILE_DMA_KT);
  const uint32_t log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint32_t half_dim = head_dim >> 1;
  std::fill(ref.begin(), ref.end(), 0.0f);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      const uint32_t pos = s + pos_offset;
      for (uint32_t h = 0; h < heads; ++h) {
        const uint32_t matrix = b * heads + h;
        for (uint32_t p = 0; p < half_dim; ++p) {
          float c = fp16_to_float(cos_table[(uint64_t)pos * half_dim + p]);
          float sn = fp16_to_float(sin_table[(uint64_t)pos * half_dim + p]);
          float x0 = fp16_to_float(input[row_index(b, s, h, p, seq, heads, head_dim)]);
          float x1 = fp16_to_float(input[row_index(b, s, h, p + half_dim, seq, heads, head_dim)]);
          float y0 = x0 * c - x1 * sn;
          float y1 = x0 * sn + x1 * c;

          if (layout_to == ROPE_LAYOUT_TO_GEMM_A) {
            const uint64_t base = batched_matrix_base(matrix, (uint64_t)output_m_pad * head_dim);
            ref[base + gemm_a_tiled_elem_offset(s, p, output_m_pad, head_dim, log2_mt, log2_mxu_kt)] = float_to_fp16(y0);
            ref[base + gemm_a_tiled_elem_offset(s, p + half_dim, output_m_pad, head_dim, log2_mt, log2_mxu_kt)] = float_to_fp16(y1);
          } else if (layout_to == ROPE_LAYOUT_TO_GEMM_W) {
            const uint64_t base = batched_matrix_base(matrix, (uint64_t)head_dim * max_seq);
            ref[base + gemm_w_tiled_wtrans1_elem_offset(p, pos, head_dim, max_seq, log2_kt, log2_mxu_kt, log2_mxu_nt)] = float_to_fp16(y0);
            ref[base + gemm_w_tiled_wtrans1_elem_offset(p + half_dim, pos, head_dim, max_seq, log2_kt, log2_mxu_kt, log2_mxu_nt)] = float_to_fp16(y1);
          } else {
            const size_t y0_off = (layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW)
                ? head_major_row_index(b, s, h, p, seq, heads, head_dim)
                : row_index(b, s, h, p, seq, heads, head_dim);
            const size_t y1_off = (layout_to == ROPE_LAYOUT_TO_HEAD_MAJOR_ROW)
                ? head_major_row_index(b, s, h, p + half_dim, seq, heads, head_dim)
                : row_index(b, s, h, p + half_dim, seq, heads, head_dim);
            ref[y0_off] = float_to_fp16(y0);
            ref[y1_off] = float_to_fp16(y1);
          }
        }
      }
    }
  }
}

int main(int argc, char *argv[]) {
  uint32_t batch = 1;
  uint32_t seq = 4;
  uint32_t heads = 1;
  uint32_t head_dim = 32;
  uint32_t max_seq = 32;
  uint32_t pos_offset = 0;
  uint32_t layout_to = ROPE_LAYOUT_TO_GEMM_A;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0) seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-headdim") == 0) head_dim = atoi(argv[++i]);
    else if (strcmp(argv[i], "-maxseq") == 0) max_seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-offset") == 0) pos_offset = atoi(argv[++i]);
    else if (strcmp(argv[i], "--layout-to") == 0) layout_to = parse_layout_to(argv[++i]);
    else if (strncmp(argv[i], "--layout-to=", 12) == 0) layout_to = parse_layout_to(argv[i] + 12);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch B] [-seq S] [-heads H] [-headdim D] "
             "[-maxseq N] [-offset O] [--layout-to gemm_a_tiled|gemm_w_tiled|row_major|head_major_row]\n", argv[0]);
      return 0;
    }
  }

  if ((head_dim & 1u) != 0 || head_dim % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: headdim must be even and a multiple of %u\n", TILE_DMA_MXU_KT);
    return 1;
  }
  if ((heads * head_dim) % TILE_DMA_MXU_NT != 0) {
    printf("ERROR: heads * headdim must be a multiple of %u\n", TILE_DMA_MXU_NT);
    return 1;
  }
  if (pos_offset + seq > max_seq) {
    printf("ERROR: offset + seq must be <= maxseq\n");
    return 1;
  }
  if (layout_to == ROPE_LAYOUT_TO_GEMM_W && max_seq % TILE_DMA_MXU_NT != 0) {
    printf("ERROR: gemm_w_tiled mode requires maxseq to be a multiple of %u\n", TILE_DMA_MXU_NT);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_KT) ||
      !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  const uint32_t input_m = batch * seq;
  const uint32_t input_m_pad = (input_m + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t output_m_pad = (seq + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t input_n = heads * head_dim;
  const size_t input_row_elems = (size_t)batch * seq * heads * head_dim;
  const size_t input_tiled_elems = (size_t)input_m_pad * input_n;
  const size_t output_elems = (layout_to == ROPE_LAYOUT_TO_GEMM_A)
      ? (size_t)batch * heads * output_m_pad * head_dim
      : (layout_to == ROPE_LAYOUT_TO_GEMM_W)
          ? (size_t)batch * heads * head_dim * max_seq
          : input_row_elems;
  const size_t input_tiled_bytes = input_tiled_elems * sizeof(data_t);
  const size_t output_bytes = output_elems * sizeof(data_t);

  printf("rope_layout_fused batch=%u seq=%u heads=%u headdim=%u maxseq=%u offset=%u layout_to=%s\n",
         batch, seq, heads, head_dim, max_seq, pos_offset,
         layout_to_name(layout_to));
#if ROPE_LAYOUT_FUSED_VARIANT_TAG == 1
  printf("variant=task_chunk16\n");
#else
  printf("variant=baseline\n");
#endif

  std::vector<data_t> h_input_row(input_row_elems);
  std::vector<data_t> h_input_tiled(input_tiled_elems);
  std::vector<data_t> h_cos;
  std::vector<data_t> h_sin;
  std::vector<data_t> h_ref(output_elems);
  std::vector<data_t> h_out(output_elems, 0);
  init_input(h_input_row);
  precompute_freqs(h_cos, h_sin, max_seq, head_dim);
  pack_projection(h_input_row, h_input_tiled, batch, seq, heads, head_dim, input_m_pad);
  build_reference(h_input_row, h_cos, h_sin, h_ref, batch, seq, heads, head_dim,
                  max_seq, pos_offset, output_m_pad, layout_to);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_tiled_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_mem_alloc(device, h_cos.size() * sizeof(data_t), VX_MEM_READ, &cos_buffer));
  RT_CHECK(vx_mem_alloc(device, h_sin.size() * sizeof(data_t), VX_MEM_READ, &sin_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input_tiled.data(), 0, input_tiled_bytes));
  RT_CHECK(vx_copy_to_dev(cos_buffer, h_cos.data(), 0, h_cos.size() * sizeof(data_t)));
  RT_CHECK(vx_copy_to_dev(sin_buffer, h_sin.data(), 0, h_sin.size() * sizeof(data_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t total_pairs = batch * seq * heads * (head_dim >> 1);
  const uint32_t blocks = std::min(
      (total_pairs + tpb - 1u) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_ROPE_LAYOUT_FUSED;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  RT_CHECK(vx_mem_address(cos_buffer, &arg.cos_addr));
  RT_CHECK(vx_mem_address(sin_buffer, &arg.sin_addr));
  arg.batch_size = batch;
  arg.seq_len = seq;
  arg.num_heads = heads;
  arg.head_dim = head_dim;
  arg.max_seq_len = max_seq;
  arg.pos_offset = pos_offset;
  arg.layout_to = layout_to;
  arg.input_m_pad = input_m_pad;
  arg.output_m_pad = output_m_pad;
  arg.log2_mt = log2_u32(TILE_DMA_MT);
  arg.log2_kt = log2_u32(TILE_DMA_KT);
  arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, output_bytes));

  int errors = 0;
  float max_diff = 0.0f;
  for (size_t i = 0; i < output_elems; ++i) {
    float got = fp16_to_float(h_out[i]);
    float expected = fp16_to_float(h_ref[i]);
    float diff = std::abs(got - expected);
    max_diff = std::max(max_diff, diff);
    if (diff > 1e-4f) {
      if (errors < 10) {
        printf("Error at %zu: got=%f expected=%f diff=%f\n", i, got, expected, diff);
      }
      ++errors;
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
