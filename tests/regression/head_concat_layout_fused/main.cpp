#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vortex.h>
#include <algorithm>
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

static uint32_t parse_layout_to(const char* value) {
  if (strcmp(value, "gemm_a_tiled") == 0 || strcmp(value, "a") == 0) {
    return 0;
  }
  printf("ERROR: --layout-to must be gemm_a_tiled\n");
  exit(1);
}

static void init_row(std::vector<data_t>& input) {
  for (size_t i = 0; i < input.size(); ++i) {
    int x = int((i * 1664525u + 1013904223u) & 0xffu) - 128;
    input[i] = float_to_fp16(float(x) / 96.0f);
  }
}

static size_t row_index(uint32_t b, uint32_t h, uint32_t s, uint32_t d,
                        uint32_t heads, uint32_t seq, uint32_t headdim) {
  return (((size_t)b * heads + h) * seq + s) * headdim + d;
}

static void pack_input(const std::vector<data_t>& row,
                       std::vector<data_t>& tiled,
                       uint32_t batch,
                       uint32_t seq,
                       uint32_t heads,
                       uint32_t headdim,
                       uint32_t input_m_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint64_t matrix_elems = (uint64_t)input_m_pad * headdim;
  std::fill(tiled.begin(), tiled.end(), 0);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t h = 0; h < heads; ++h) {
      const uint64_t base = batched_matrix_base(b * heads + h, matrix_elems);
      for (uint32_t s = 0; s < seq; ++s) {
        for (uint32_t d = 0; d < headdim; ++d) {
          tiled[base + gemm_c_tiled_elem_offset(
              s, d, input_m_pad, headdim, log2_mt, log2_mxu_nt)] =
              row[row_index(b, h, s, d, heads, seq, headdim)];
        }
      }
    }
  }
}

static void build_reference(const std::vector<data_t>& row,
                            std::vector<data_t>& ref,
                            uint32_t batch,
                            uint32_t seq,
                            uint32_t heads,
                            uint32_t headdim,
                            uint32_t output_m_pad) {
  const uint32_t log2_mt = log2_u32(TILE_DMA_MT);
  const uint32_t log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  const uint32_t hidden = heads * headdim;
  std::fill(ref.begin(), ref.end(), 0);
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      const uint32_t m = b * seq + s;
      for (uint32_t h = 0; h < heads; ++h) {
        for (uint32_t d = 0; d < headdim; ++d) {
          const uint32_t k = h * headdim + d;
          const uint64_t out_off = gemm_a_tiled_elem_offset(
              m, k, output_m_pad, hidden, log2_mt, log2_mxu_kt);
          ref[out_off] = row[row_index(b, h, s, d, heads, seq, headdim)];
        }
      }
    }
  }
}

int main(int argc, char *argv[]) {
  uint32_t batch = 1;
  uint32_t seq = 4;
  uint32_t heads = 2;
  uint32_t headdim = 32;

  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-batch") == 0) batch = atoi(argv[++i]);
    else if (strcmp(argv[i], "-seq") == 0) seq = atoi(argv[++i]);
    else if (strcmp(argv[i], "-heads") == 0) heads = atoi(argv[++i]);
    else if (strcmp(argv[i], "-headdim") == 0) headdim = atoi(argv[++i]);
    else if (strcmp(argv[i], "--layout-to") == 0) (void)parse_layout_to(argv[++i]);
    else if (strncmp(argv[i], "--layout-to=", 12) == 0) (void)parse_layout_to(argv[i] + 12);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch B] [-seq S] [-heads H] [-headdim D] "
             "[--layout-to gemm_a_tiled]\n", argv[0]);
      return 0;
    }
  }

  const uint32_t hidden = heads * headdim;
  if (headdim % TILE_DMA_MXU_NT != 0 || hidden % TILE_DMA_MXU_KT != 0) {
    printf("ERROR: headdim must be multiple of %u and hidden multiple of %u\n",
           TILE_DMA_MXU_NT, TILE_DMA_MXU_KT);
    return 1;
  }
  if (!is_pow2(TILE_DMA_MT) || !is_pow2(TILE_DMA_MXU_KT) || !is_pow2(TILE_DMA_MXU_NT)) {
    printf("ERROR: tile constants must be powers of two\n");
    return 1;
  }

  const uint32_t input_m_pad = (seq + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const uint32_t output_m = batch * seq;
  const uint32_t output_m_pad = (output_m + TILE_M_PAD_ALIGN - 1u) & ~(TILE_M_PAD_ALIGN - 1u);
  const size_t row_elems = (size_t)batch * heads * seq * headdim;
  const size_t input_elems = (size_t)batch * heads * input_m_pad * headdim;
  const size_t output_elems = (size_t)output_m_pad * hidden;
  const size_t input_bytes = input_elems * sizeof(data_t);
  const size_t output_bytes = output_elems * sizeof(data_t);

  std::vector<data_t> h_row(row_elems);
  std::vector<data_t> h_input(input_elems);
  std::vector<data_t> h_ref(output_elems);
  std::vector<data_t> h_out(output_elems);
  init_row(h_row);
  pack_input(h_row, h_input, batch, seq, heads, headdim, input_m_pad);
  build_reference(h_row, h_ref, batch, seq, heads, headdim, output_m_pad);

  printf("head_concat_layout_fused batch=%u seq=%u heads=%u headdim=%u\n",
         batch, seq, heads, headdim);
#if HEAD_CONCAT_LAYOUT_FUSED_VARIANT_TAG == 1
  printf("variant=chunk16_packed\n");
#else
  printf("variant=baseline\n");
#endif

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, input_bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, input_bytes));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t blocks = std::min(
      (uint32_t)((row_elems + tpb - 1) / tpb),
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_HEAD_CONCAT_LAYOUT_FUSED;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(input_buffer, &arg.input_addr));
  RT_CHECK(vx_mem_address(output_buffer, &arg.output_addr));
  arg.batch = batch;
  arg.seq = seq;
  arg.heads = heads;
  arg.headdim = headdim;
  arg.input_m_pad = input_m_pad;
  arg.output_m_pad = output_m_pad;
  arg.log2_mt = log2_u32(TILE_DMA_MT);
  arg.log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  arg.log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, output_bytes));

  int errors = 0;
  for (size_t i = 0; i < output_elems; ++i) {
    if (h_out[i] != h_ref[i]) {
      if (errors < 10) {
        printf("Error at %zu: got=0x%04x expected=0x%04x\n", i, h_out[i], h_ref[i]);
      }
      ++errors;
    }
  }

  vx_dump_perf(device, stdout);
  cleanup();
  if (errors == 0) {
    printf("PASSED!\n");
    return 0;
  }
  printf("FAILED! errors=%d\n", errors);
  return 1;
}
