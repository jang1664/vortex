#include "common.h"
#include "../vector_common/fp16.h"
#include <vortex.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using data_t = fp16_t;

#ifndef HEAD_CONCAT_VARIANT_TAG
#define HEAD_CONCAT_VARIANT_TAG 0
#endif

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

static void init_input(std::vector<data_t>& input) {
  for (size_t i = 0; i < input.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    input[i] = float_to_fp16(float(x) / 80.0f);
  }
}

static void build_reference(const std::vector<data_t>& input,
                            std::vector<data_t>& ref,
                            uint32_t batch,
                            uint32_t seq,
                            uint32_t heads,
                            uint32_t headdim) {
  const uint32_t hidden = heads * headdim;
  for (uint32_t b = 0; b < batch; ++b) {
    for (uint32_t s = 0; s < seq; ++s) {
      for (uint32_t h = 0; h < heads; ++h) {
        for (uint32_t d = 0; d < headdim; ++d) {
          const uint64_t in_off =
              (((uint64_t)b * heads + h) * seq + s) * headdim + d;
          const uint64_t out_off =
              ((uint64_t)b * seq + s) * hidden + h * headdim + d;
          ref[out_off] = input[in_off];
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
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-batch B] [-seq S] [-heads H] [-headdim D]\n", argv[0]);
      return 0;
    }
  }

  const uint32_t hidden = heads * headdim;
  const size_t elems = (size_t)batch * seq * hidden;
  const size_t bytes = elems * sizeof(data_t);
  std::vector<data_t> h_input(elems);
  std::vector<data_t> h_ref(elems);
  std::vector<data_t> h_out(elems);
  init_input(h_input);
  build_reference(h_input, h_ref, batch, seq, heads, headdim);

#if HEAD_CONCAT_VARIANT_TAG == 1
  const char* variant = "chunk16_packed";
  const uint32_t work_items =
      batch * seq * heads * ((headdim + 15u) >> 4);
#else
  const char* variant = "baseline";
  const uint32_t work_items = static_cast<uint32_t>(elems);
#endif
  printf("head_concat batch=%u seq=%u heads=%u headdim=%u variant=%s\n",
         batch, seq, heads, headdim, variant);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, bytes, VX_MEM_READ, &input_buffer));
  RT_CHECK(vx_mem_alloc(device, bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(input_buffer, h_input.data(), 0, bytes));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t blocks = std::min(
      (work_items + tpb - 1) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_HEAD_CONCAT;
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
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), output_buffer, 0, bytes));

  int errors = 0;
  for (size_t i = 0; i < elems; ++i) {
    if (h_out[i] != h_ref[i]) {
      if (errors < 10) {
        printf("Error at %zu: got=0x%04x expected=0x%04x\n",
               i, h_out[i], h_ref[i]);
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
