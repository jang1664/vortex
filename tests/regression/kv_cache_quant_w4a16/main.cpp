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

static void init_src(std::vector<fp16_t>& src) {
  for (size_t i = 0; i < src.size(); ++i) {
    int x = int((i * 1103515245u + 12345u) & 0xffu) - 128;
    src[i] = float_to_fp16(float(x) / 64.0f);
  }
}

static void compute_params_cpu(const std::vector<fp16_t>& src,
                               uint32_t K,
                               uint32_t N,
                               uint32_t QBLK,
                               uint32_t QDIR,
                               uint32_t k,
                               uint32_t n,
                               fp16_t& scale_bits,
                               int16_t& zp) {
  float min_v = fp16_to_float(src[(uint64_t)k * N + n]);
  float max_v = min_v;
  if (QDIR == 0) {
    uint32_t k0 = (k / QBLK) * QBLK;
    uint32_t k1 = std::min(K, k0 + QBLK);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      float v = fp16_to_float(src[(uint64_t)kk * N + n]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
    }
  } else {
    uint32_t n0 = (n / QBLK) * QBLK;
    uint32_t n1 = std::min(N, n0 + QBLK);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      float v = fp16_to_float(src[(uint64_t)k * N + nn]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
    }
  }

  const float range = max_v - min_v;
  float scale = 1.0f;
  float inv_for_zp = 1.0f;
  if (range != 0.0f) {
    scale = range / 15.0f;
    inv_for_zp = 15.0f / range;
  }
  int32_t zpi = kv_round_half_away_from_zero(-min_v * inv_for_zp);
  if (zpi < 0) zpi = 0;
  if (zpi > 15) zpi = 15;
  scale_bits = float_to_fp16(scale);
  zp = (int16_t)zpi;
}

static void quantize_cpu(const std::vector<fp16_t>& src,
                         std::vector<uint8_t>& packed,
                         std::vector<fp16_t>& scales,
                         std::vector<int16_t>& zeros,
                         uint32_t K,
                         uint32_t N,
                         uint32_t QBLK,
                         uint32_t QDIR) {
  std::fill(packed.begin(), packed.end(), 0);
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; ++n) {
      fp16_t scale_bits = 0;
      int16_t zp = 0;
      compute_params_cpu(src, K, N, QBLK, QDIR, k, n, scale_bits, zp);
      uint64_t qidx = kv_qparam_index(k, n, K, N, QBLK, QDIR);
      scales[qidx] = scale_bits;
      zeros[qidx] = zp;
    }
    for (uint32_t n = 0; n < N; n += 2) {
      uint64_t qidx0 = kv_qparam_index(k, n, K, N, QBLK, QDIR);
      uint64_t qidx1 = kv_qparam_index(k, n + 1, K, N, QBLK, QDIR);
      const float scale0 = fp16_to_float(scales[qidx0]);
      const float scale1 = fp16_to_float(scales[qidx1]);
      const float inv_scale0 = (scale0 == 0.0f) ? 0.0f : (1.0f / scale0);
      const float inv_scale1 = (scale1 == 0.0f) ? 0.0f : (1.0f / scale1);
      uint8_t q0 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n]), inv_scale0, zeros[qidx0]);
      uint8_t q1 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n + 1]), inv_scale1, zeros[qidx1]);
      kv_store_npair(packed.data(), N, k, n >> 1, q0, q1);
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

  const size_t src_elems = (size_t)K * N;
  const size_t packed_bytes = src_elems / 2;
  const size_t qparam_elems = kv_qparam_count(K, N, QBLK, QDIR);
  std::vector<fp16_t> h_src(src_elems);
  std::vector<uint8_t> h_packed(packed_bytes);
  std::vector<uint8_t> h_ref_packed(packed_bytes);
  std::vector<fp16_t> h_scales(qparam_elems);
  std::vector<fp16_t> h_ref_scales(qparam_elems);
  std::vector<int16_t> h_zeros(qparam_elems);
  std::vector<int16_t> h_ref_zeros(qparam_elems);
  init_src(h_src);
  quantize_cpu(h_src, h_ref_packed, h_ref_scales, h_ref_zeros, K, N, QBLK, QDIR);

  printf("kv_cache_quant_w4a16 K=%u N=%u QBLK=%u QDIR=%u WTRANS=%u\n",
         K, N, QBLK, QDIR, WTRANS);
  printf("variant=%s\n", kv_cache_quant_variant_name());

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(fp16_t), VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, packed_bytes, VX_MEM_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(fp16_t), VX_MEM_WRITE, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, qparam_elems * sizeof(int16_t), VX_MEM_WRITE, &zero_buffer));
  RT_CHECK(vx_copy_to_dev(src_buffer, h_src.data(), 0, src_elems * sizeof(fp16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  uint32_t tpb = kv_cache_quant_threads_per_block(num_warps, num_threads);
  uint32_t work_items = kv_cache_quant_work_items(K, N, QBLK, QDIR);
  uint32_t blocks = kv_cache_quant_blocks(
      work_items, tpb, num_cores, num_warps);

  kernel_arg_t arg = {};
  arg.kernel_id = KERNEL_KV_CACHE_QUANT_W4A16;
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
  RT_CHECK(vx_copy_from_dev(h_packed.data(), dst_buffer, 0, packed_bytes));
  RT_CHECK(vx_copy_from_dev(h_scales.data(), scale_buffer, 0, qparam_elems * sizeof(fp16_t)));
  RT_CHECK(vx_copy_from_dev(h_zeros.data(), zero_buffer, 0, qparam_elems * sizeof(int16_t)));

  int errors = 0;
  for (size_t i = 0; i < packed_bytes; ++i) {
    if (h_packed[i] != h_ref_packed[i]) ++errors;
  }
  for (size_t i = 0; i < qparam_elems; ++i) {
    if (h_scales[i] != h_ref_scales[i] || h_zeros[i] != h_ref_zeros[i]) ++errors;
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
