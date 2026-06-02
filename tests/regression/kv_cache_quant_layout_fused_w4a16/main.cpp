#include "host_common.h"
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
vx_buffer_h weight_buffer = nullptr;
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
  if (weight_buffer) vx_mem_free(weight_buffer);
  if (scale_buffer) vx_mem_free(scale_buffer);
  if (zero_buffer) vx_mem_free(zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
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
    const uint32_t k0 = (k / QBLK) * QBLK;
    const uint32_t k1 = std::min(K, k0 + QBLK);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const float v = fp16_to_float(src[(uint64_t)kk * N + n]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
    }
  } else {
    const uint32_t n0 = (n / QBLK) * QBLK;
    const uint32_t n1 = std::min(N, n0 + QBLK);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const float v = fp16_to_float(src[(uint64_t)k * N + nn]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
    }
  }

  float scale = (max_v - min_v) / 15.0f;
  if (scale == 0.0f) scale = 1.0f;
  const float zpf = -min_v / scale;
  int32_t zpi = (int32_t)(zpf + ((zpf >= 0.0f) ? 0.5f : -0.5f));
  if (zpi < 0) zpi = 0;
  if (zpi > 15) zpi = 15;
  scale_bits = float_to_fp16(scale);
  zp = (int16_t)zpi;
}

static uint8_t quant_cpu(const std::vector<fp16_t>& src,
                         uint32_t K,
                         uint32_t N,
                         uint32_t QBLK,
                         uint32_t QDIR,
                         uint32_t k,
                         uint32_t n) {
  fp16_t scale_bits = 0;
  int16_t zp = 0;
  compute_params_cpu(src, K, N, QBLK, QDIR, k, n, scale_bits, zp);
  return kv_quantize_value(fp16_to_float(src[(uint64_t)k * N + n]),
                           fp16_to_float(scale_bits), zp);
}

static uint64_t weight_offset_wtrans0(uint32_t K,
                                      uint32_t N,
                                      uint32_t k,
                                      uint32_t n_pair) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt = k / TILE_DMA_KT;
  const uint32_t kt_start = kt * TILE_DMA_KT;
  const uint32_t ck = std::min(K - kt_start, (uint32_t)TILE_DMA_KT);
  const uint32_t nt = (n_pair << 1) / TILE_DMA_MXU_NT;
  const uint32_t pair = n_pair & ((TILE_DMA_MXU_NT >> 1) - 1u);
  const uint32_t k_local = k - kt_start;
  const uint32_t kb = k_local / TILE_DMA_MXU_KT;
  const uint32_t k_in_sub = k_local & (TILE_DMA_MXU_KT - 1u);
  const uint32_t tid = kb * TILE_DMA_MXU_KT + k_in_sub;
  return (uint64_t)kt * TILE_DMA_KT * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)tid * (TILE_DMA_MXU_NT >> 1)
       + pair;
}

static uint64_t weight_offset_wtrans1(uint32_t K,
                                      uint32_t N,
                                      uint32_t k0,
                                      uint32_t n) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt = k0 / TILE_DMA_KT;
  const uint32_t kt_start = kt * TILE_DMA_KT;
  const uint32_t ck = std::min(K - kt_start, (uint32_t)TILE_DMA_KT);
  const uint32_t nt = n / TILE_DMA_MXU_NT;
  const uint32_t n_in_sub = n & (TILE_DMA_MXU_NT - 1u);
  const uint32_t k_local = k0 - kt_start;
  const uint32_t kb = k_local / TILE_DMA_MXU_KT;
  const uint32_t k_pair = (k_local & (TILE_DMA_MXU_KT - 1u)) >> 1;
  const uint32_t micro_bytes = TILE_DMA_MXU_NT * (TILE_DMA_MXU_KT >> 1);
  return (uint64_t)kt * TILE_DMA_KT * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)kb * micro_bytes
       + (uint64_t)n_in_sub * (TILE_DMA_MXU_KT >> 1)
       + k_pair;
}

static uint64_t scale_slot_base_ref(uint32_t K,
                                    uint32_t N,
                                    uint32_t QBLK,
                                    uint32_t QDIR,
                                    uint32_t kt,
                                    uint32_t nt_dma) {
  uint64_t base = 0;
  const uint32_t k_tiles = (K + TILE_DMA_KT - 1u) / TILE_DMA_KT;
  const uint32_t n_dma_tiles = (N + TILE_DMA_NT - 1u) / TILE_DMA_NT;
  for (uint32_t prev_kt = 0; prev_kt < kt; ++prev_kt) {
    const uint32_t prev_k =
        std::min(K - prev_kt * TILE_DMA_KT, (uint32_t)TILE_DMA_KT);
    for (uint32_t prev_nt = 0; prev_nt < n_dma_tiles; ++prev_nt) {
      const uint32_t prev_n =
          std::min(N - prev_nt * TILE_DMA_NT, (uint32_t)TILE_DMA_NT);
      base += scale_slot_bytes_host(prev_k, prev_n, QBLK, QDIR);
    }
  }
  const uint32_t cur_k = std::min(K - kt * TILE_DMA_KT, (uint32_t)TILE_DMA_KT);
  for (uint32_t prev_nt = 0; prev_nt < nt_dma; ++prev_nt) {
    const uint32_t prev_n =
        std::min(N - prev_nt * TILE_DMA_NT, (uint32_t)TILE_DMA_NT);
    base += scale_slot_bytes_host(cur_k, prev_n, QBLK, QDIR);
  }
  (void)k_tiles;
  return base;
}

static void store_u16_ref(std::vector<uint8_t>& dst, uint64_t off, uint16_t value) {
  dst[off] = (uint8_t)(value & 0xffu);
  dst[off + 1] = (uint8_t)(value >> 8);
}

static void quantize_layout_fused_cpu(const std::vector<fp16_t>& src,
                                      std::vector<uint8_t>& weight,
                                      std::vector<uint8_t>& scales,
                                      std::vector<uint8_t>& zeros,
                                      uint32_t K,
                                      uint32_t N,
                                      uint32_t QBLK,
                                      uint32_t QDIR,
                                      uint32_t WTRANS) {
  std::fill(weight.begin(), weight.end(), 0);
  std::fill(scales.begin(), scales.end(), 0);
  std::fill(zeros.begin(), zeros.end(), 0);

  if (WTRANS == 0) {
    for (uint32_t k = 0; k < K; ++k) {
      for (uint32_t n = 0; n < N; n += 2) {
        const uint8_t q0 = quant_cpu(src, K, N, QBLK, QDIR, k, n);
        const uint8_t q1 = quant_cpu(src, K, N, QBLK, QDIR, k, n + 1);
        weight[weight_offset_wtrans0(K, N, k, n >> 1)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else {
    for (uint32_t k = 0; k < K; k += 2) {
      for (uint32_t n = 0; n < N; ++n) {
        const uint8_t q0 = quant_cpu(src, K, N, QBLK, QDIR, k, n);
        const uint8_t q1 = quant_cpu(src, K, N, QBLK, QDIR, k + 1, n);
        weight[weight_offset_wtrans1(K, N, k, n)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  }

  const uint32_t k_tiles = (K + TILE_DMA_KT - 1u) / TILE_DMA_KT;
  const uint32_t n_dma_tiles = (N + TILE_DMA_NT - 1u) / TILE_DMA_NT;
  const uint32_t mxu_per_dma_nt = TILE_DMA_NT / TILE_DMA_MXU_NT;
  const uint32_t ng_per_mxu_nt = (TILE_DMA_MXU_NT + QBLK - 1u) / QBLK;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t kt_start = kt * TILE_DMA_KT;
    const uint32_t cur_k = std::min(K - kt_start, (uint32_t)TILE_DMA_KT);
    const uint32_t cur_groups = cur_k / QBLK;
    for (uint32_t nt_dma = 0; nt_dma < n_dma_tiles; ++nt_dma) {
      const uint32_t nt_start = nt_dma * TILE_DMA_NT;
      const uint32_t cur_n = std::min(N - nt_start, (uint32_t)TILE_DMA_NT);
      const uint32_t cur_nb = cur_n / TILE_DMA_MXU_NT;
      uint64_t out = scale_slot_base_ref(K, N, QBLK, QDIR, kt, nt_dma);
      if (QDIR == 0) {
        for (uint32_t nb = 0; nb < cur_nb; ++nb) {
          for (uint32_t g = 0; g < cur_groups; ++g) {
            for (uint32_t col = 0; col < TILE_DMA_MXU_NT; ++col) {
              fp16_t scale_bits = 0;
              int16_t zp = 0;
              compute_params_cpu(src, K, N, QBLK, QDIR,
                                 kt_start + g * QBLK,
                                 nt_start + nb * TILE_DMA_MXU_NT + col,
                                 scale_bits, zp);
              store_u16_ref(scales, out, scale_bits);
              store_u16_ref(zeros, out, (uint16_t)zp);
              out += TILE_ELEM_BYTES;
            }
          }
        }
      } else {
        for (uint32_t nb = 0; nb < cur_nb; ++nb) {
          const uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
          const uint32_t ng_start = (global_nt_mxu * TILE_DMA_MXU_NT) / QBLK;
          for (uint32_t k = 0; k < cur_k; ++k) {
            for (uint32_t ng = 0; ng < ng_per_mxu_nt; ++ng) {
              fp16_t scale_bits = 0;
              int16_t zp = 0;
              compute_params_cpu(src, K, N, QBLK, QDIR,
                                 kt_start + k,
                                 (ng_start + ng) * QBLK,
                                 scale_bits, zp);
              store_u16_ref(scales, out, scale_bits);
              store_u16_ref(zeros, out, (uint16_t)zp);
              out += TILE_ELEM_BYTES;
            }
          }
        }
      }
    }
  }
}

int main(int argc, char *argv[]) {
  uint32_t K = 32;
  uint32_t N = 32;
  uint32_t QBLK = 16;
  uint32_t QDIR = 0;
  uint32_t WTRANS = 0;
  uint32_t src_layout = SRC_LAYOUT_ROW_MAJOR;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-n") == 0) N = atoi(argv[++i]);
    else if (strcmp(argv[i], "-q") == 0) QBLK = atoi(argv[++i]);
    else if (strcmp(argv[i], "-d") == 0) QDIR = atoi(argv[++i]);
    else if (strcmp(argv[i], "-t") == 0) WTRANS = atoi(argv[++i]);
    else if (strcmp(argv[i], "--layout-from") == 0) src_layout = parse_src_layout(argv[++i]);
    else if (strncmp(argv[i], "--layout-from=", 14) == 0) src_layout = parse_src_layout(argv[i] + 14);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-k K] [-n N] [-q QBLK] [-d QDIR] [-t WTRANS] "
             "[--layout-from row_major_fp16|gemm_c_tiled]\n", argv[0]);
      return 0;
    }
  }
  if (!valid_fused_quant_shape(K, N, QBLK, QDIR, WTRANS)) {
    printf("ERROR: require K,N multiples of 32, even N, pow2 QBLK, "
           "QDIR/WTRANS in {0,1}, and quant axis divisible by QBLK\n");
    return 1;
  }

  const size_t src_elems = (size_t)K * N;
  const size_t weight_bytes = src_elems / 2;
  const size_t scale_bytes = scale_total_bytes_host(K, N, QBLK, QDIR);
  std::vector<fp16_t> h_src(src_elems);
  std::vector<uint8_t> h_weight(weight_bytes);
  std::vector<uint8_t> h_ref_weight(weight_bytes);
  std::vector<uint8_t> h_scales(scale_bytes);
  std::vector<uint8_t> h_ref_scales(scale_bytes);
  std::vector<uint8_t> h_zeros(scale_bytes);
  std::vector<uint8_t> h_ref_zeros(scale_bytes);
  init_src(h_src);
  std::vector<fp16_t> h_src_device(src_elems);
  pack_src_for_layout(h_src, h_src_device, K, N, src_layout);
  quantize_layout_fused_cpu(h_src, h_ref_weight, h_ref_scales, h_ref_zeros,
                            K, N, QBLK, QDIR, WTRANS);

  printf("kv_cache_quant_layout_fused_w4a16 K=%u N=%u QBLK=%u QDIR=%u WTRANS=%u layout_from=%s\n",
         K, N, QBLK, QDIR, WTRANS, src_layout_name(src_layout));

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, src_elems * sizeof(fp16_t), VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, weight_bytes, VX_MEM_WRITE, &weight_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_WRITE, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_WRITE, &zero_buffer));
  RT_CHECK(vx_copy_to_dev(src_buffer, h_src_device.data(), 0, src_elems * sizeof(fp16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));

  kernel_arg_t arg = {};
  const uint32_t max_slot_elems = max_scale_slot_bytes_host(K, N, QBLK, QDIR) / TILE_ELEM_BYTES;
  const uint32_t n_dma_tiles = (N + TILE_DMA_NT - 1u) / TILE_DMA_NT;
  const uint32_t k_tiles = (K + TILE_DMA_KT - 1u) / TILE_DMA_KT;
  const uint32_t qparam_work = k_tiles * n_dma_tiles * max_slot_elems;
  const uint32_t work_items = std::max((uint32_t)weight_bytes, qparam_work);
  const uint32_t blocks = std::min(
      (work_items + tpb - 1u) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));
  if (!init_kernel_arg(arg, K, N, QBLK, QDIR, WTRANS, src_layout, blocks, tpb)) {
    printf("ERROR: failed to initialize kernel args\n");
    cleanup();
    return 1;
  }
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(weight_buffer, &arg.weight_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_weight.data(), weight_buffer, 0, weight_bytes));
  RT_CHECK(vx_copy_from_dev(h_scales.data(), scale_buffer, 0, scale_bytes));
  RT_CHECK(vx_copy_from_dev(h_zeros.data(), zero_buffer, 0, scale_bytes));

  size_t errors = 0;
  for (size_t i = 0; i < weight_bytes; ++i) {
    if (h_weight[i] != h_ref_weight[i]) {
      if (errors < 8) {
        printf("Weight mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
               i, unsigned(h_weight[i]), unsigned(h_ref_weight[i]));
      }
      ++errors;
    }
  }
  for (size_t i = 0; i < scale_bytes; ++i) {
    if (h_scales[i] != h_ref_scales[i]) {
      if (errors < 8) {
        printf("Scale mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
               i, unsigned(h_scales[i]), unsigned(h_ref_scales[i]));
      }
      ++errors;
    }
    if (h_zeros[i] != h_ref_zeros[i]) {
      if (errors < 8) {
        printf("Zero mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
               i, unsigned(h_zeros[i]), unsigned(h_ref_zeros[i]));
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
  printf("FAILED! errors=%zu\n", errors);
  return 1;
}
