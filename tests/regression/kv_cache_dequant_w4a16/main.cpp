#include "common.h"
#include "host_variant.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vortex.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;

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
  if (src_buffer) vx_mem_free(src_buffer);
  if (dst_buffer) vx_mem_free(dst_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static void init_quantized(std::vector<uint8_t>& packed,
                           std::vector<fp16_t>& scales,
                           std::vector<int16_t>& zeros,
                           uint32_t K,
                           uint32_t N,
                           uint32_t QBLK,
                           uint32_t QDIR) {
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; n += 2) {
      uint8_t q0 = (uint8_t)((k + n) & 0x0f);
      uint8_t q1 = (uint8_t)((k + n + 7u) & 0x0f);
      kv_store_npair(packed.data(), N, k, n >> 1, q0, q1);
    }
  }
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; ++n) {
      uint64_t qidx = kv_qparam_index(k, n, K, N, QBLK, QDIR);
      scales[qidx] = float_to_fp16(0.125f + float((qidx % 7u)) * 0.03125f);
      zeros[qidx] = (int16_t)(qidx % 5u);
    }
  }
}

static void dequant_cpu(const std::vector<uint8_t>& packed,
                        const std::vector<fp16_t>& scales,
                        const std::vector<int16_t>& zeros,
                        std::vector<fp16_t>& dst,
                        uint32_t K,
                        uint32_t N,
                        uint32_t QBLK,
                        uint32_t QDIR) {
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; ++n) {
      uint8_t q = kv_get_nibble(packed.data(), K, N, k, n);
      uint64_t qidx = kv_qparam_index(k, n, K, N, QBLK, QDIR);
      dst[(uint64_t)k * N + n] =
          float_to_fp16(((float)q - (float)zeros[qidx]) * fp16_to_float(scales[qidx]));
    }
  }
}

int main(int argc, char *argv[]) {
  uint32_t K = 32;
  uint32_t N = 32;
  uint32_t QBLK = 16;
  uint32_t QDIR = 0;
  uint32_t WTRANS = 0;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-n") == 0) N = atoi(argv[++i]);
    else if (strcmp(argv[i], "-q") == 0) QBLK = atoi(argv[++i]);
    else if (strcmp(argv[i], "-d") == 0) QDIR = atoi(argv[++i]);
    else if (strcmp(argv[i], "-t") == 0) WTRANS = atoi(argv[++i]);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-k K] [-n N] [-q QBLK] [-d QDIR] [-t WTRANS]\n", argv[0]);
      return 0;
    }
  }
  if ((N & 1u) != 0 || QBLK == 0 || QDIR > 1 || WTRANS > 1) {
    printf("ERROR: require even N, QBLK>0, QDIR in {0,1}, WTRANS in {0,1}\n");
    return 1;
  }

  const size_t dst_elems = (size_t)K * N;
  const size_t packed_bytes = dst_elems / 2;
  const size_t qparam_elems = kv_qparam_count(K, N, QBLK, QDIR);
  std::vector<uint8_t> h_packed(packed_bytes);
  std::vector<fp16_t> h_scales(qparam_elems);
  std::vector<int16_t> h_zeros(qparam_elems);
  std::vector<fp16_t> h_ref(dst_elems);
  std::vector<fp16_t> h_out(dst_elems);
  init_quantized(h_packed, h_scales, h_zeros, K, N, QBLK, QDIR);
  dequant_cpu(h_packed, h_scales, h_zeros, h_ref, K, N, QBLK, QDIR);

  printf("kv_cache_dequant_w4a16 K=%u N=%u QBLK=%u QDIR=%u WTRANS=%u\n",
         K, N, QBLK, QDIR, WTRANS);
  printf("variant=%s\n", kv_cache_dequant_variant_name());

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, packed_bytes, VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, dst_elems * sizeof(fp16_t), VX_MEM_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(fp16_t), VX_MEM_READ, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(int16_t), VX_MEM_READ, &zero_buffer));
  RT_CHECK(vx_copy_to_dev(src_buffer, h_packed.data(), 0, packed_bytes));
  RT_CHECK(vx_copy_to_dev(scale_buffer, h_scales.data(), 0, qparam_elems * sizeof(fp16_t)));
  RT_CHECK(vx_copy_to_dev(zero_buffer, h_zeros.data(), 0, qparam_elems * sizeof(int16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));
  uint32_t work_items = kv_cache_dequant_work_items(K, N);
  uint32_t blocks = std::min(
      (work_items + tpb - 1u) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_KV_CACHE_DEQUANT_W4A16;
  arg.grid_dim[0] = blocks;
  arg.grid_dim[1] = 1;
  arg.grid_dim[2] = 1;
  arg.block_dim[0] = tpb;
  arg.block_dim[1] = 1;
  arg.block_dim[2] = 1;
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(dst_buffer, &arg.dst_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  arg.K = K;
  arg.N = N;
  arg.QBLK = QBLK;
  arg.QDIR = QDIR;
  arg.WTRANS = WTRANS;
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_out.data(), dst_buffer, 0, dst_elems * sizeof(fp16_t)));

  int errors = 0;
  for (size_t i = 0; i < dst_elems; ++i) {
    if (h_out[i] != h_ref[i]) ++errors;
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
