#include "host_common.h"
#include <vortex.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifndef KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG
#define KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG 0
#endif

vx_device_h device = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h weight_buffer = nullptr;
vx_buffer_h scale_buffer = nullptr;
vx_buffer_h zero_buffer = nullptr;
vx_buffer_h logical_scale_buffer = nullptr;
vx_buffer_h logical_zero_buffer = nullptr;

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
  if (logical_scale_buffer) vx_mem_free(logical_scale_buffer);
  if (logical_zero_buffer) vx_mem_free(logical_zero_buffer);
  if (krnl_buffer) vx_mem_free(krnl_buffer);
  if (args_buffer) vx_mem_free(args_buffer);
  if (device) vx_dev_close(device);
}

static int32_t round_half_even_cpu(float value) {
  const int32_t truncated = (int32_t)value;
  const float truncated_f = (float)truncated;
  const int32_t floor_value = truncated - (int32_t)(truncated_f > value);
  const float fraction = value - (float)floor_value;
  return floor_value + (int32_t)(fraction > 0.5f)
      + (int32_t)(fraction == 0.5f && (floor_value & 1));
}

static void compute_params_cpu(const std::vector<fp16_t>& src,
                               uint32_t K,
                               uint32_t N,
                               uint32_t QBLK,
                               uint32_t QDIR,
                               uint32_t quant_mode,
                               uint32_t k,
                               uint32_t n,
                               fp16_t& scale_bits,
                               fp16_t& zero_bits,
                               float* scale_fp32 = nullptr,
                               float* zero_fp32 = nullptr) {
  if (k >= K || n >= N) {
    scale_bits = 0;
    zero_bits = 0;
    return;
  }
  float min_v = fp16_to_float(src[(uint64_t)k * N + n]);
  float max_v = min_v;
  float absmax = std::fabs(min_v);
  if (QDIR == 0) {
    const uint32_t k0 = (k >> log2_u32(QBLK)) << log2_u32(QBLK);
    const uint32_t k1 = std::min(K, k0 + QBLK);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const float v = fp16_to_float(src[(uint64_t)kk * N + n]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
      absmax = std::max(absmax, std::fabs(v));
    }
  } else {
    const uint32_t n0 = (n >> log2_u32(QBLK)) << log2_u32(QBLK);
    const uint32_t n1 = std::min(N, n0 + QBLK);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const float v = fp16_to_float(src[(uint64_t)k * N + nn]);
      min_v = std::min(min_v, v);
      max_v = std::max(max_v, v);
      absmax = std::max(absmax, std::fabs(v));
    }
  }

  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const float scale = std::max(absmax, 1e-8f) / 7.5f;
    scale_bits = float_to_fp16(scale);
    zero_bits = 0;
    if (scale_fp32) *scale_fp32 = scale;
    if (zero_fp32) *zero_fp32 = 0.0f;
    return;
  }

  const float range = max_v - min_v;
  float scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  float inv_for_zp = 1.0f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
    inv_for_zp = 15.0f / range;
  }
  scale_bits = float_to_fp16(scale);
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    const float zero = (float)round_half_even_cpu(-min_v / scale) - 8.0f;
    zero_bits = float_to_fp16(zero);
    if (scale_fp32) *scale_fp32 = scale;
    if (zero_fp32) *zero_fp32 = zero;
  } else {
    int32_t zpi = kv_round_half_away_from_zero(-min_v * inv_for_zp);
    if (zpi < 0) zpi = 0;
    if (zpi > 15) zpi = 15;
    zero_bits = float_to_fp16((float)zpi);
    if (scale_fp32) *scale_fp32 = scale;
    if (zero_fp32) *zero_fp32 = (float)zpi;
  }
}

static uint8_t quant_cpu(const std::vector<fp16_t>& src,
                         uint32_t K,
                         uint32_t N,
                         uint32_t QBLK,
                         uint32_t QDIR,
                         uint32_t quant_mode,
                         uint32_t k,
                         uint32_t n) {
  if (k >= K || n >= N) {
    return 0;
  }
  fp16_t scale_bits = 0;
  fp16_t zero_bits = 0;
  float scale_fp32 = 0.0f;
  float zero_fp32 = 0.0f;
  compute_params_cpu(src, K, N, QBLK, QDIR, quant_mode, k, n,
                     scale_bits, zero_bits, &scale_fp32, &zero_fp32);
  const float stored_scale = fp16_to_float(scale_bits);
  const float quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? stored_scale : scale_fp32;
  const float inv_scale = (quant_scale == 0.0f) ? 0.0f : (1.0f / quant_scale);
  const float value = fp16_to_float(src[(uint64_t)k * N + n]);
  const float zero = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? fp16_to_float(zero_bits) : zero_fp32;
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return kv_quantize_value_inv_scale(value, inv_scale, (int16_t)zero);
  }
  int32_t q = round_half_even_cpu(value * inv_scale) + (int32_t)zero;
  q = std::max(-8, std::min(7, q));
  return (uint8_t)(q & 0x0f);
}

static uint8_t quant_source_cpu(const std::vector<fp16_t>& src,
                                uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t QDIR,
                                uint32_t quant_mode,
                                uint32_t out_k,
                                uint32_t out_n,
                                uint32_t source_transposed) {
  const uint32_t source_row = source_transposed ? out_n : out_k;
  const uint32_t source_col = source_transposed ? out_k : out_n;
  if (source_row >= K || source_col >= N) {
    return 0;
  }
  return quant_cpu(src, K, N, QBLK, QDIR, quant_mode, source_row, source_col);
}

static uint64_t weight_offset_wtrans0(uint32_t K,
                                      uint32_t N,
                                      uint32_t k,
                                      uint32_t n_pair,
                                      uint32_t dma_kt) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t log2_kt = log2_u32(dma_kt);
  const uint32_t log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint32_t kt = k >> log2_kt;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = std::min(K - kt_start, dma_kt);
  const uint32_t nt = (n_pair << 1) >> log2_mxu_nt;
  const uint32_t pair = n_pair & ((TILE_DMA_MXU_NT >> 1) - 1u);
  const uint32_t k_local = k - kt_start;
  const uint32_t kb = k_local >> log2_mxu_kt;
  const uint32_t k_in_sub = k_local & (TILE_DMA_MXU_KT - 1u);
  const uint32_t tid = kb * TILE_DMA_MXU_KT + k_in_sub;
  return (uint64_t)kt * dma_kt * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)tid * (TILE_DMA_MXU_NT >> 1)
       + pair;
}

static uint64_t weight_offset_wtrans1(uint32_t K,
                                      uint32_t N,
                                      uint32_t k0,
                                      uint32_t n,
                                      uint32_t dma_kt) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t log2_kt = log2_u32(dma_kt);
  const uint32_t log2_mxu_kt = log2_u32(TILE_DMA_MXU_KT);
  const uint32_t log2_mxu_nt = log2_u32(TILE_DMA_MXU_NT);
  const uint32_t kt = k0 >> log2_kt;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = std::min(K - kt_start, dma_kt);
  const uint32_t nt = n >> log2_mxu_nt;
  const uint32_t n_in_sub = n & (TILE_DMA_MXU_NT - 1u);
  const uint32_t k_local = k0 - kt_start;
  const uint32_t kb = k_local >> log2_mxu_kt;
  const uint32_t k_pair = (k_local & (TILE_DMA_MXU_KT - 1u)) >> 1;
  const uint32_t micro_bytes = TILE_DMA_MXU_NT * (TILE_DMA_MXU_KT >> 1);
  return (uint64_t)kt * dma_kt * row_bytes
       + (uint64_t)nt * ck * (TILE_DMA_MXU_NT >> 1)
       + (uint64_t)kb * micro_bytes
       + (uint64_t)n_in_sub * (TILE_DMA_MXU_KT >> 1)
       + k_pair;
}

static uint64_t scale_slot_base_ref(uint32_t K,
                                    uint32_t N,
                                    uint32_t QBLK,
                                    uint32_t QDIR,
                                    uint32_t source_transposed,
                                    uint32_t dma_kt,
                                    uint32_t dma_nt,
                                    uint32_t kt,
                                    uint32_t nt_dma) {
  uint64_t base = 0;
  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, QDIR, source_transposed);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, dma_kt);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, dma_nt);
  for (uint32_t prev_kt = 0; prev_kt < kt; ++prev_kt) {
    const uint32_t prev_k =
        std::min(out_K - prev_kt * dma_kt, dma_kt);
    for (uint32_t prev_nt = 0; prev_nt < n_dma_tiles; ++prev_nt) {
      const uint32_t prev_n =
          std::min(out_N - prev_nt * dma_nt, dma_nt);
      base += scale_slot_bytes_host(prev_k, prev_n, QBLK, QDIR);
    }
  }
  const uint32_t cur_k = std::min(out_K - kt * dma_kt, dma_kt);
  for (uint32_t prev_nt = 0; prev_nt < nt_dma; ++prev_nt) {
    const uint32_t prev_n =
        std::min(out_N - prev_nt * dma_nt, dma_nt);
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
                                      uint32_t quant_mode,
                                      uint32_t WTRANS,
                                      uint32_t GEMM_QDIR,
                                      uint32_t SOURCE_TRANSPOSED,
                                      uint32_t dma_kt,
                                      uint32_t dma_nt) {
  std::fill(weight.begin(), weight.end(), 0);
  std::fill(scales.begin(), scales.end(), 0);
  std::fill(zeros.begin(), zeros.end(), 0);

  if (SOURCE_TRANSPOSED) {
    const uint32_t logical_K = padded_weight_K_host(K, N, SOURCE_TRANSPOSED);
    const uint32_t logical_N = padded_weight_N_host(K, N, SOURCE_TRANSPOSED);
    for (uint32_t k = 0; k < logical_K; k += 2) {
      for (uint32_t n = 0; n < logical_N; ++n) {
        const uint8_t q0 = quant_source_cpu(src, K, N, QBLK, QDIR, quant_mode,
                                            k, n, SOURCE_TRANSPOSED);
        const uint8_t q1 = quant_source_cpu(src, K, N, QBLK, QDIR, quant_mode,
                                            k + 1, n, SOURCE_TRANSPOSED);
        weight[weight_offset_wtrans1(logical_K, logical_N, k, n, dma_kt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else if (WTRANS == 0) {
    const uint32_t logical_K = padded_weight_K_host(K, N, SOURCE_TRANSPOSED);
    const uint32_t logical_N = padded_weight_N_host(K, N, SOURCE_TRANSPOSED);
    for (uint32_t k = 0; k < logical_K; ++k) {
      for (uint32_t n = 0; n < logical_N; n += 2) {
        const uint8_t q0 = quant_cpu(src, K, N, QBLK, QDIR, quant_mode, k, n);
        const uint8_t q1 = quant_cpu(src, K, N, QBLK, QDIR, quant_mode, k, n + 1);
        weight[weight_offset_wtrans0(logical_K, logical_N, k, n >> 1, dma_kt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else {
    const uint32_t logical_K = padded_weight_K_host(K, N, SOURCE_TRANSPOSED);
    const uint32_t logical_N = padded_weight_N_host(K, N, SOURCE_TRANSPOSED);
    for (uint32_t k = 0; k < logical_K; k += 2) {
      for (uint32_t n = 0; n < logical_N; ++n) {
        const uint8_t q0 = quant_cpu(src, K, N, QBLK, QDIR, quant_mode, k, n);
        const uint8_t q1 = quant_cpu(src, K, N, QBLK, QDIR, quant_mode, k + 1, n);
        weight[weight_offset_wtrans1(logical_K, logical_N, k, n, dma_kt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  }

  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, dma_kt);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, dma_nt);
  const uint32_t mxu_per_dma_nt = dma_nt >> log2_u32(TILE_DMA_MXU_NT);
  const uint32_t ng_per_mxu_nt = ceil_div_pow2_u32(TILE_DMA_MXU_NT, QBLK);
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t kt_start = kt * dma_kt;
    const uint32_t cur_k = std::min(out_K - kt_start, dma_kt);
    const uint32_t cur_groups = cur_k >> log2_u32(QBLK);
    for (uint32_t nt_dma = 0; nt_dma < n_dma_tiles; ++nt_dma) {
      const uint32_t nt_start = nt_dma * dma_nt;
      const uint32_t cur_n = std::min(out_N - nt_start, dma_nt);
      const uint32_t cur_nb = cur_n >> log2_u32(TILE_DMA_MXU_NT);
      uint64_t out = scale_slot_base_ref(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED,
                                         dma_kt, dma_nt, kt, nt_dma);
      if (GEMM_QDIR == 0) {
        for (uint32_t nb = 0; nb < cur_nb; ++nb) {
          for (uint32_t g = 0; g < cur_groups; ++g) {
            for (uint32_t col = 0; col < TILE_DMA_MXU_NT; ++col) {
              fp16_t scale_bits = 0;
              fp16_t zero_bits = 0;
              const uint32_t param_k = kt_start + (g << log2_u32(QBLK));
              const uint32_t param_n = nt_start + (nb << log2_u32(TILE_DMA_MXU_NT)) + col;
              const uint32_t source_row = SOURCE_TRANSPOSED ? param_n : param_k;
              const uint32_t source_col = SOURCE_TRANSPOSED ? param_k : param_n;
              if (source_row < K && source_col < N) {
                compute_params_cpu(src, K, N, QBLK, QDIR, quant_mode,
                                   source_row, source_col, scale_bits, zero_bits);
              }
              store_u16_ref(scales, out, scale_bits);
              store_u16_ref(zeros, out,
                            quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
                                ? 0u : (uint16_t)(int16_t)fp16_to_float(zero_bits));
              out += TILE_ELEM_BYTES;
            }
          }
        }
      } else {
        for (uint32_t nb = 0; nb < cur_nb; ++nb) {
          const uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
          const uint32_t ng_start = (global_nt_mxu << log2_u32(TILE_DMA_MXU_NT)) >> log2_u32(QBLK);
          for (uint32_t k = 0; k < cur_k; ++k) {
            for (uint32_t ng = 0; ng < ng_per_mxu_nt; ++ng) {
              fp16_t scale_bits = 0;
              fp16_t zero_bits = 0;
              const uint32_t param_k = kt_start + k;
              const uint32_t param_n = (ng_start + ng) << log2_u32(QBLK);
              const uint32_t source_row = SOURCE_TRANSPOSED ? param_n : param_k;
              const uint32_t source_col = SOURCE_TRANSPOSED ? param_k : param_n;
              if (source_row < K && source_col < N) {
                compute_params_cpu(src, K, N, QBLK, QDIR, quant_mode,
                                   source_row, source_col, scale_bits, zero_bits);
              }
              store_u16_ref(scales, out, scale_bits);
              store_u16_ref(zeros, out,
                            quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
                                ? 0u : (uint16_t)(int16_t)fp16_to_float(zero_bits));
              out += TILE_ELEM_BYTES;
            }
          }
        }
      }
    }
  }
}

static int run_persistent_update_test(uint32_t capacity,
                                      uint32_t position,
                                      uint32_t persistent_kind,
                                      bool emit_correction_qparams) {
  constexpr uint32_t N = 128;
  constexpr uint32_t QBLK = 128;
  constexpr uint32_t QDIR = 1;
  constexpr uint32_t DMA_MT = DEFAULT_DMA_MT;
  constexpr uint32_t DMA_KT = DEFAULT_DMA_KT;
  constexpr uint32_t DMA_NT = DEFAULT_DMA_NT;
  const uint32_t source_transposed = persistent_kind == 1 ? 1u : 0u;
  const uint32_t wtrans = source_transposed;
  const uint32_t gemm_qdir = persistent_kind == 1 ? 0u : 1u;
  const uint32_t quant_mode = persistent_kind == 1
      ? KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC
      : KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC;
  if (capacity == 0 || position >= capacity) {
    printf("ERROR: persistent position must be smaller than non-zero capacity\n");
    return 1;
  }

  std::vector<fp16_t> token(N);
  init_src(token);
  std::vector<fp16_t> initial_src((size_t)capacity * N, 0);
  std::vector<fp16_t> reference_src = initial_src;
  std::copy(token.begin(), token.end(),
            reference_src.begin() + (uint64_t)position * N);

  const size_t weight_bytes = weight_total_bytes_host(
      capacity, N, source_transposed);
  const size_t scale_bytes = scale_total_bytes_host(
      capacity, N, QBLK, gemm_qdir, source_transposed, DMA_KT, DMA_NT);
  const size_t logical_count = kv_qparam_count(capacity, N, QBLK, QDIR);
  std::vector<uint8_t> weight(weight_bytes);
  std::vector<uint8_t> scale(scale_bytes);
  std::vector<uint8_t> zero(scale_bytes);
  std::vector<uint8_t> initial_weight(weight_bytes);
  std::vector<uint8_t> initial_scale(scale_bytes);
  std::vector<uint8_t> initial_zero(scale_bytes);
  std::vector<uint8_t> reference_weight(weight_bytes);
  std::vector<uint8_t> reference_scale(scale_bytes);
  std::vector<uint8_t> reference_zero(scale_bytes);
  quantize_layout_fused_cpu(
      initial_src, initial_weight, initial_scale, initial_zero,
      capacity, N, QBLK, QDIR, quant_mode, wtrans, gemm_qdir,
      source_transposed, DMA_KT, DMA_NT);
  quantize_layout_fused_cpu(
      reference_src, reference_weight, reference_scale, reference_zero,
      capacity, N, QBLK, QDIR, quant_mode, wtrans, gemm_qdir,
      source_transposed, DMA_KT, DMA_NT);

  std::vector<fp16_t> logical_scale(logical_count);
  std::vector<fp16_t> logical_zero(logical_count);
  std::vector<fp16_t> reference_logical_scale(logical_count);
  std::vector<fp16_t> reference_logical_zero(logical_count);
  for (uint32_t k = 0; k < capacity; ++k) {
    compute_params_cpu(initial_src, capacity, N, QBLK, QDIR, quant_mode,
                       k, 0, logical_scale[k], logical_zero[k]);
    compute_params_cpu(reference_src, capacity, N, QBLK, QDIR, quant_mode,
                       k, 0, reference_logical_scale[k], reference_logical_zero[k]);
  }

  printf("persistent KV update kind=%s capacity=%u position=%u\n",
         persistent_kind == 1 ? "K" : "V", capacity, position);
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, token.size() * sizeof(fp16_t),
                        VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, weight_bytes, VX_MEM_READ_WRITE, &weight_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_READ_WRITE, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_READ_WRITE, &zero_buffer));
  if (emit_correction_qparams) {
    RT_CHECK(vx_mem_alloc(device, logical_count * sizeof(fp16_t),
                          VX_MEM_READ_WRITE, &logical_scale_buffer));
    RT_CHECK(vx_mem_alloc(device, logical_count * sizeof(fp16_t),
                          VX_MEM_READ_WRITE, &logical_zero_buffer));
  }
  RT_CHECK(vx_copy_to_dev(src_buffer, token.data(), 0,
                          token.size() * sizeof(fp16_t)));
  RT_CHECK(vx_copy_to_dev(weight_buffer, initial_weight.data(), 0, weight_bytes));
  RT_CHECK(vx_copy_to_dev(scale_buffer, initial_scale.data(), 0, scale_bytes));
  RT_CHECK(vx_copy_to_dev(zero_buffer, initial_zero.data(), 0, scale_bytes));
  if (emit_correction_qparams) {
    RT_CHECK(vx_copy_to_dev(logical_scale_buffer, logical_scale.data(), 0,
                            logical_count * sizeof(fp16_t)));
    RT_CHECK(vx_copy_to_dev(logical_zero_buffer, logical_zero.data(), 0,
                            logical_count * sizeof(fp16_t)));
  }

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG >= 2
      ? (uint32_t)num_threads
      : std::min(256u, (uint32_t)(num_warps * num_threads));
  const uint32_t work_items = std::max(N >> 1, gemm_qdir == 0 ? 1u : N >> 5);
  const uint32_t blocks = KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT_TAG >= 2
      ? 1u
      : std::min(
            (work_items + tpb - 1u) / tpb,
            std::max(1u, (uint32_t)num_cores * 4u));

  kernel_arg_t arg = {};
  if (!init_kernel_arg(arg, capacity, N, QBLK, QDIR, wtrans, gemm_qdir,
                       source_transposed, SRC_LAYOUT_ROW_MAJOR,
                       DMA_MT, DMA_KT, DMA_NT, blocks, tpb, quant_mode, N, 0)) {
    printf("ERROR: failed to initialize persistent kernel args\n");
    cleanup();
    return 1;
  }
  arg.K = 1;
  arg.src_total_K = 1;
  arg.persistent_mode = 1;
  arg.cache_capacity = capacity;
  arg.cache_position = position;
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(weight_buffer, &arg.weight_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  if (emit_correction_qparams) {
    RT_CHECK(vx_mem_address(logical_scale_buffer, &arg.logical_scale_addr));
    RT_CHECK(vx_mem_address(logical_zero_buffer, &arg.logical_zero_addr));
  }
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(weight.data(), weight_buffer, 0, weight_bytes));
  RT_CHECK(vx_copy_from_dev(scale.data(), scale_buffer, 0, scale_bytes));
  RT_CHECK(vx_copy_from_dev(zero.data(), zero_buffer, 0, scale_bytes));
  if (emit_correction_qparams) {
    RT_CHECK(vx_copy_from_dev(logical_scale.data(), logical_scale_buffer, 0,
                              logical_count * sizeof(fp16_t)));
    RT_CHECK(vx_copy_from_dev(logical_zero.data(), logical_zero_buffer, 0,
                              logical_count * sizeof(fp16_t)));
  }

  size_t errors = 0;
  auto check_bytes = [&errors](const char* name,
                               const std::vector<uint8_t>& actual,
                               const std::vector<uint8_t>& expected) {
    for (size_t i = 0; i < actual.size(); ++i) {
      if (actual[i] != expected[i]) {
        if (errors < 8) {
          printf("%s mismatch at byte %zu: got=0x%02x ref=0x%02x\n",
                 name, i, unsigned(actual[i]), unsigned(expected[i]));
        }
        ++errors;
      }
    }
  };
  check_bytes("Weight", weight, reference_weight);
  check_bytes("Scale", scale, reference_scale);
  check_bytes("Zero", zero, reference_zero);
  if (emit_correction_qparams) {
    for (size_t i = 0; i < logical_count; ++i) {
      if (logical_scale[i] != reference_logical_scale[i]
          || logical_zero[i] != reference_logical_zero[i]) {
        if (errors < 8) {
          printf("Logical qparam mismatch at %zu\n", i);
        }
        ++errors;
      }
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

int main(int argc, char *argv[]) {
  uint32_t K = 32;
  uint32_t N = 32;
  uint32_t QBLK = 32;
  uint32_t DMA_MT = DEFAULT_DMA_MT;
  uint32_t DMA_KT = DEFAULT_DMA_KT;
  uint32_t DMA_NT = DEFAULT_DMA_NT;
  uint32_t QDIR = 0;
  uint32_t WTRANS = 0;
  uint32_t GEMM_QDIR = 0;
  uint32_t SOURCE_TRANSPOSED = 0;
  uint32_t quant_mode = KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  uint32_t source_total_n = 0;
  uint32_t head_col_offset = 0;
  bool emit_correction_qparams = false;
  bool gemm_qdir_set = false;
  bool append_update = false;
  uint32_t persistent_kind = 0;
  uint32_t cache_capacity = 0;
  uint32_t cache_position = 0;
  uint32_t src_layout = SRC_LAYOUT_ROW_MAJOR;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-k") == 0) K = atoi(argv[++i]);
    else if (strcmp(argv[i], "-n") == 0) N = atoi(argv[++i]);
    else if (strcmp(argv[i], "-q") == 0) QBLK = atoi(argv[++i]);
    else if (strcmp(argv[i], "-d") == 0) QDIR = atoi(argv[++i]);
    else if (strcmp(argv[i], "-t") == 0) WTRANS = atoi(argv[++i]);
    else if (strcmp(argv[i], "--mt") == 0) DMA_MT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--mt=", 5) == 0) DMA_MT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--kt") == 0) DMA_KT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--kt=", 5) == 0) DMA_KT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--nt") == 0) DMA_NT = atoi(argv[++i]);
    else if (strncmp(argv[i], "--nt=", 5) == 0) DMA_NT = atoi(argv[i] + 5);
    else if (strcmp(argv[i], "--gemm-qdir") == 0) {
      GEMM_QDIR = atoi(argv[++i]);
      gemm_qdir_set = true;
    }
    else if (strncmp(argv[i], "--gemm-qdir=", 13) == 0) {
      GEMM_QDIR = atoi(argv[i] + 13);
      gemm_qdir_set = true;
    }
    else if (strcmp(argv[i], "--source-transposed") == 0) SOURCE_TRANSPOSED = 1;
    else if (strcmp(argv[i], "--quant-mode") == 0) quant_mode = parse_quant_mode(argv[++i]);
    else if (strncmp(argv[i], "--quant-mode=", 13) == 0) quant_mode = parse_quant_mode(argv[i] + 13);
    else if (strcmp(argv[i], "--source-total-n") == 0) source_total_n = atoi(argv[++i]);
    else if (strncmp(argv[i], "--source-total-n=", 17) == 0) source_total_n = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--head-col-offset") == 0) head_col_offset = atoi(argv[++i]);
    else if (strncmp(argv[i], "--head-col-offset=", 18) == 0) head_col_offset = atoi(argv[i] + 18);
    else if (strcmp(argv[i], "--emit-correction-qparams") == 0) emit_correction_qparams = true;
    else if (strcmp(argv[i], "--persistent-kind") == 0) {
      const char* kind = argv[++i];
      persistent_kind = strcmp(kind, "k") == 0 ? 1u : strcmp(kind, "v") == 0 ? 2u : 0u;
    }
    else if (strcmp(argv[i], "--cache-update") == 0) {
      const char* mode = argv[++i];
      if (strcmp(mode, "full") == 0) append_update = false;
      else if (strcmp(mode, "append") == 0) append_update = true;
      else {
        printf("ERROR: --cache-update must be full or append\n");
        return 1;
      }
    }
    else if (strncmp(argv[i], "--cache-update=", 15) == 0) {
      const char* mode = argv[i] + 15;
      if (strcmp(mode, "full") == 0) append_update = false;
      else if (strcmp(mode, "append") == 0) append_update = true;
      else {
        printf("ERROR: --cache-update must be full or append\n");
        return 1;
      }
    }
    else if (strcmp(argv[i], "--cache-capacity") == 0) cache_capacity = atoi(argv[++i]);
    else if (strncmp(argv[i], "--cache-capacity=", 17) == 0) cache_capacity = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--cache-position") == 0) cache_position = atoi(argv[++i]);
    else if (strncmp(argv[i], "--cache-position=", 17) == 0) cache_position = atoi(argv[i] + 17);
    else if (strcmp(argv[i], "--layout-from") == 0) src_layout = parse_src_layout(argv[++i]);
    else if (strncmp(argv[i], "--layout-from=", 14) == 0) src_layout = parse_src_layout(argv[i] + 14);
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-k K] [-n N] [-q QBLK] [-d QDIR] [-t WTRANS] "
             "[--mt MT] [--kt KT] [--nt NT] "
             "[--gemm-qdir QDIR] [--source-transposed] "
             "[--layout-from row_major_fp16|gemm_c_tiled] "
             "[--quant-mode legacy_uint4_asymmetric|spinquant_signed_asymmetric|spinquant_signed_symmetric] "
             "[--source-total-n N] [--head-col-offset N] [--emit-correction-qparams] "
             "[--cache-update full|append] "
             "[--persistent-kind k|v --cache-capacity N --cache-position N]\n", argv[0]);
      return 0;
    }
  }
  if (!gemm_qdir_set) GEMM_QDIR = QDIR;
  if (persistent_kind != 0) {
    return run_persistent_update_test(cache_capacity, cache_position,
                                      persistent_kind, true);
  }
  if (append_update) {
    if (K != 1 || N != 128 || QBLK != 128 || QDIR != 1
        || cache_capacity == 0 || cache_position >= cache_capacity) {
      printf("ERROR: append correctness mode requires K=1, N=128, "
             "QBLK=128, QDIR=1, and cache-position < cache-capacity\n");
      return 1;
    }
    if (SOURCE_TRANSPOSED != 0 && WTRANS == 1 && GEMM_QDIR == 0
        && quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
      persistent_kind = 1;
    } else if (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && GEMM_QDIR == 1
               && quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
      persistent_kind = 2;
    } else {
      printf("ERROR: append correctness mode supports the decode KV-K "
             "and KV-V configurations\n");
      return 1;
    }
    return run_persistent_update_test(cache_capacity, cache_position,
                                      persistent_kind,
                                      emit_correction_qparams);
  }
  if (source_total_n == 0) source_total_n = N;
  if (!valid_fused_quant_shape(K, N, QBLK, QDIR, WTRANS, GEMM_QDIR,
                               SOURCE_TRANSPOSED, quant_mode,
                               source_total_n, head_col_offset)) {
    printf("ERROR: require non-zero K/N, even N, pow2 QBLK, "
           "source_QDIR/GEMM_QDIR/WTRANS in {0,1}, and source-transposed requires WTRANS=1\n");
    return 1;
  }
  if (!is_pow2_u32(DMA_MT) || !is_pow2_u32(DMA_KT) || !is_pow2_u32(DMA_NT) ||
      (DMA_KT & (TILE_DMA_MXU_KT - 1u)) != 0 ||
      (DMA_NT & (TILE_DMA_MXU_NT - 1u)) != 0 ||
      (GEMM_QDIR == 0 && DMA_KT < QBLK)) {
    printf("ERROR: MT/KT/NT must be powers of two, KT%%MXU_KT=0, "
           "NT%%MXU_NT=0, and GEMM_QDIR=0 requires KT>=QBLK\n");
    return 1;
  }

  const size_t src_elems = (size_t)K * N;
  const size_t src_alloc_elems = (size_t)align_up_u32_host(K, TILE_DMA_MXU_KT) * source_total_n;
  const size_t weight_bytes = weight_total_bytes_host(K, N, SOURCE_TRANSPOSED);
  const size_t scale_bytes = scale_total_bytes_host(K, N, QBLK, GEMM_QDIR,
                                                    SOURCE_TRANSPOSED, DMA_KT, DMA_NT);
  std::vector<fp16_t> h_src(src_elems);
  std::vector<uint8_t> h_weight(weight_bytes);
  std::vector<uint8_t> h_ref_weight(weight_bytes);
  std::vector<uint8_t> h_scales(scale_bytes);
  std::vector<uint8_t> h_ref_scales(scale_bytes);
  std::vector<uint8_t> h_zeros(scale_bytes);
  std::vector<uint8_t> h_ref_zeros(scale_bytes);
  init_src(h_src);
  std::vector<fp16_t> h_src_combined((size_t)K * source_total_n, 0);
  for (uint32_t k = 0; k < K; ++k) {
    std::copy_n(h_src.begin() + (uint64_t)k * N, N,
                h_src_combined.begin() + (uint64_t)k * source_total_n + head_col_offset);
  }
  std::vector<fp16_t> h_src_device(src_alloc_elems);
  pack_src_for_layout(h_src_combined, h_src_device, K, source_total_n, src_layout, DMA_MT);
  quantize_layout_fused_cpu(h_src, h_ref_weight, h_ref_scales, h_ref_zeros,
                            K, N, QBLK, QDIR, quant_mode, WTRANS, GEMM_QDIR,
                            SOURCE_TRANSPOSED, DMA_KT, DMA_NT);

  const size_t logical_qparam_count = kv_qparam_count(K, N, QBLK, QDIR);
  std::vector<fp16_t> h_logical_scales(logical_qparam_count);
  std::vector<fp16_t> h_logical_zeros(logical_qparam_count);
  std::vector<fp16_t> h_ref_logical_scales(logical_qparam_count);
  std::vector<fp16_t> h_ref_logical_zeros(logical_qparam_count);
  for (uint32_t k = 0; k < K; ++k) {
    for (uint32_t n = 0; n < N; ++n) {
      const uint64_t index = kv_qparam_index(k, n, K, N, QBLK, QDIR);
      compute_params_cpu(h_src, K, N, QBLK, QDIR, quant_mode, k, n,
                         h_ref_logical_scales[index], h_ref_logical_zeros[index]);
    }
  }

  printf("kv_cache_quant_layout_fused_w4a16 K=%u N=%u QBLK=%u source_QDIR=%u gemm_QDIR=%u WTRANS=%u source_transposed=%u layout_from=%s quant_mode=%s source_total_n=%u head_col_offset=%u\n",
         K, N, QBLK, QDIR, GEMM_QDIR, WTRANS, SOURCE_TRANSPOSED,
         src_layout_name(src_layout), quant_mode_name(quant_mode),
         source_total_n, head_col_offset);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, src_alloc_elems * sizeof(fp16_t), VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_alloc(device, weight_bytes, VX_MEM_WRITE, &weight_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_WRITE, &scale_buffer));
  RT_CHECK(vx_mem_alloc(device, scale_bytes, VX_MEM_WRITE, &zero_buffer));
  if (emit_correction_qparams) {
    RT_CHECK(vx_mem_alloc(device, logical_qparam_count * sizeof(fp16_t), VX_MEM_WRITE,
                          &logical_scale_buffer));
    RT_CHECK(vx_mem_alloc(device, logical_qparam_count * sizeof(fp16_t), VX_MEM_WRITE,
                          &logical_zero_buffer));
  }
  RT_CHECK(vx_copy_to_dev(src_buffer, h_src_device.data(), 0, src_alloc_elems * sizeof(fp16_t)));

  uint64_t num_cores = 0;
  uint64_t num_warps = 0;
  uint64_t num_threads = 0;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  const uint32_t tpb = std::min(256u, (uint32_t)(num_warps * num_threads));

  kernel_arg_t arg = {};
  const uint32_t max_slot_elems = max_scale_slot_bytes_host(K, N, QBLK, GEMM_QDIR,
                                                            SOURCE_TRANSPOSED, DMA_KT, DMA_NT)
                                / TILE_ELEM_BYTES;
  const uint32_t out_K = padded_qparam_K_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N_host(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t n_dma_tiles = ceil_div_pow2_u32(out_N, DMA_NT);
  const uint32_t k_tiles = ceil_div_pow2_u32(out_K, DMA_KT);
  const uint32_t qparam_work = k_tiles * n_dma_tiles * max_slot_elems;
  const uint32_t work_items = std::max((uint32_t)weight_bytes, qparam_work);
  const uint32_t blocks = std::min(
      (work_items + tpb - 1u) / tpb,
      std::max(1u, (uint32_t)num_cores * 4u));
  if (!init_kernel_arg(arg, K, N, QBLK, QDIR, WTRANS, GEMM_QDIR,
                       SOURCE_TRANSPOSED, src_layout, DMA_MT, DMA_KT, DMA_NT,
                       blocks, tpb, quant_mode, source_total_n, head_col_offset)) {
    printf("ERROR: failed to initialize kernel args\n");
    cleanup();
    return 1;
  }
  RT_CHECK(vx_mem_address(src_buffer, &arg.src_addr));
  RT_CHECK(vx_mem_address(weight_buffer, &arg.weight_addr));
  RT_CHECK(vx_mem_address(scale_buffer, &arg.scale_addr));
  RT_CHECK(vx_mem_address(zero_buffer, &arg.zero_addr));
  if (emit_correction_qparams) {
    RT_CHECK(vx_mem_address(logical_scale_buffer, &arg.logical_scale_addr));
    RT_CHECK(vx_mem_address(logical_zero_buffer, &arg.logical_zero_addr));
  }
  RT_CHECK(vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer));

  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_weight.data(), weight_buffer, 0, weight_bytes));
  RT_CHECK(vx_copy_from_dev(h_scales.data(), scale_buffer, 0, scale_bytes));
  RT_CHECK(vx_copy_from_dev(h_zeros.data(), zero_buffer, 0, scale_bytes));
  if (emit_correction_qparams) {
    RT_CHECK(vx_copy_from_dev(h_logical_scales.data(), logical_scale_buffer, 0,
                              logical_qparam_count * sizeof(fp16_t)));
    RT_CHECK(vx_copy_from_dev(h_logical_zeros.data(), logical_zero_buffer, 0,
                              logical_qparam_count * sizeof(fp16_t)));
  }

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
  if (emit_correction_qparams) {
    for (size_t i = 0; i < logical_qparam_count; ++i) {
      if (h_logical_scales[i] != h_ref_logical_scales[i] ||
          h_logical_zeros[i] != h_ref_logical_zeros[i]) {
        if (errors < 8) {
          printf("Logical qparam mismatch at %zu: scale=0x%04x/0x%04x zero=0x%04x/0x%04x\n",
                 i, unsigned(h_logical_scales[i]), unsigned(h_ref_logical_scales[i]),
                 unsigned(h_logical_zeros[i]), unsigned(h_ref_logical_zeros[i]));
        }
        ++errors;
      }
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
