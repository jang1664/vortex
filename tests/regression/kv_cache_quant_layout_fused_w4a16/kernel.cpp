#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

#ifndef KV_FUSED_QPARAM_WARP
#define KV_FUSED_QPARAM_WARP 0
#endif

static inline uint32_t float_to_bits(float value) {
  union { float f; uint32_t u; } v;
  v.f = value;
  return v.u;
}

static inline float bits_to_float(uint32_t value) {
  union { uint32_t u; float f; } v;
  v.u = value;
  return v.f;
}

static inline float shfl_down_float(float value, uint32_t offset) {
  return bits_to_float((uint32_t)vx_shfl_down(
      float_to_bits(value), offset, NUM_THREADS - 1, 0));
}

static inline float shfl_idx_float(float value, uint32_t index) {
  return bits_to_float((uint32_t)vx_shfl_idx(
      float_to_bits(value), index, NUM_THREADS - 1, 0));
}

static inline int32_t round_half_even(float value) {
  const int32_t truncated = (int32_t)value;
  const float truncated_f = (float)truncated;
  const int32_t floor_value = truncated - (int32_t)(truncated_f > value);
  const float fraction = value - (float)floor_value;
  const int32_t round_up = (int32_t)(fraction > 0.5f)
      | ((int32_t)(fraction == 0.5f) & (floor_value & 1));
  return floor_value + round_up;
}

static uint32_t min_u32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

static uint32_t align_up_u32(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

static uint64_t gemm_c_tiled_offset(uint32_t K,
                                    uint32_t N,
                                    uint32_t k,
                                    uint32_t n,
                                    uint32_t log2_mt,
                                    uint32_t log2_mxu_nt) {
  const uint32_t mt_size = 1u << log2_mt;
  const uint32_t mt = k >> log2_mt;
  const uint32_t m0 = k & (mt_size - 1u);
  const uint32_t cm = min_u32(K - (mt << log2_mt), mt_size);
  const uint32_t nt32 = n >> log2_mxu_nt;
  const uint32_t n0 = n & (TILE_DMA_MXU_NT - 1u);
  return (uint64_t)mt * mt_size * N
       + (uint64_t)nt32 * cm * TILE_DMA_MXU_NT
       + (uint64_t)m0 * TILE_DMA_MXU_NT
       + n0;
}

static uint64_t gemm_a_tiled_offset(uint32_t K,
                                    uint32_t N,
                                    uint32_t k,
                                    uint32_t n,
                                    uint32_t log2_mt,
                                    uint32_t log2_mxu_kt) {
  const uint32_t mt_size = 1u << log2_mt;
  const uint32_t mt = k >> log2_mt;
  const uint32_t m0 = k & (mt_size - 1u);
  const uint32_t cm = min_u32(K - (mt << log2_mt), mt_size);
  const uint32_t km = n >> log2_mxu_kt;
  const uint32_t k0 = n & ((1u << log2_mxu_kt) - 1u);
  return (uint64_t)mt * mt_size * N
       + (uint64_t)km * cm * (1u << log2_mxu_kt)
       + (uint64_t)m0 * (1u << log2_mxu_kt)
       + k0;
}

struct source_view_t {
  uint32_t total_k;
  uint32_t total_n;
  uint32_t row_offset;
  uint32_t col_offset;
};

static fp16_t load_src_value(const fp16_t* src,
                             uint32_t K,
                             uint32_t N,
                             uint32_t k,
                             uint32_t n,
                             uint32_t src_layout,
                             uint32_t log2_mt,
                             uint32_t log2_mxu_nt,
                             const source_view_t& source_view) {
  if (k >= K || n >= N) {
    return 0;
  }
  const uint32_t physical_k = k + source_view.row_offset;
  const uint32_t physical_n = n + source_view.col_offset;
  if (src_layout == SRC_LAYOUT_GEMM_C_TILED) {
    return src[gemm_c_tiled_offset(source_view.total_k, source_view.total_n,
                                   physical_k, physical_n,
                                   log2_mt, log2_mxu_nt)];
  }
  if (src_layout == SRC_LAYOUT_GEMM_A_TILED) {
    return src[gemm_a_tiled_offset(source_view.total_k, source_view.total_n,
                                   physical_k, physical_n,
                                   log2_mt, log2_mxu_nt)];
  }
  return src[(uint64_t)physical_k * source_view.total_n + physical_n];
}

static void compute_params(const fp16_t* src,
                           uint32_t K,
                           uint32_t N,
                           uint32_t QBLK,
                           uint32_t QDIR,
                           uint32_t k,
                           uint32_t n,
                           uint32_t src_layout,
                           uint32_t log2_qblk,
                           uint32_t log2_mt,
                           uint32_t log2_mxu_nt,
                           uint32_t quant_mode,
                           const source_view_t& source_view,
                           float* scale_out,
                           float* zero_out) {
  if (k >= K || n >= N) {
    *scale_out = 0.0f;
    *zero_out = 0.0f;
    return;
  }
  float min_v = fp16_to_float(load_src_value(src, K, N, k, n, src_layout,
                                             log2_mt, log2_mxu_nt,
                                             source_view));
  float max_v = min_v;
  float absmax = min_v < 0.0f ? -min_v : min_v;

  if (QDIR == 0) {
    const uint32_t k0 = (k >> log2_qblk) << log2_qblk;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const float v = fp16_to_float(load_src_value(src, K, N, kk, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
      const float abs_v = v < 0.0f ? -v : v;
      if (abs_v > absmax) absmax = abs_v;
    }
  } else {
    const uint32_t n0 = (n >> log2_qblk) << log2_qblk;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const float v = fp16_to_float(load_src_value(src, K, N, k, nn, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
      const float abs_v = v < 0.0f ? -v : v;
      if (abs_v > absmax) absmax = abs_v;
    }
  }

  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    if (absmax < 1e-8f) absmax = 1e-8f;
    *scale_out = absmax / 7.5f;
    *zero_out = 0.0f;
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
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *scale_out = scale;
    *zero_out = -8.0f - min_v / scale;
  } else {
    int32_t zp = kv_round_half_away_from_zero(-min_v * inv_for_zp);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
    *scale_out = scale;
    *zero_out = (float)zp;
  }
}

static void compute_params_warp(const fp16_t* src,
                                uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t QDIR,
                                uint32_t k,
                                uint32_t n,
                                uint32_t src_layout,
                                uint32_t log2_qblk,
                                uint32_t log2_mt,
                                uint32_t log2_mxu_nt,
                                uint32_t quant_mode,
                                const source_view_t& source_view,
                                uint32_t lane,
                                float* scale_out,
                                float* zero_out) {
  if (k >= K || n >= N) {
    *scale_out = 0.0f;
    *zero_out = 0.0f;
    return;
  }
  float min_v = 3.402823466e+38F;
  float max_v = -3.402823466e+38F;
  if (QDIR == 0) {
    const uint32_t k0 = (k >> log2_qblk) << log2_qblk;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0 + lane; kk < k1; kk += NUM_THREADS) {
      const float v = fp16_to_float(load_src_value(
          src, K, N, kk, n, src_layout, log2_mt, log2_mxu_nt,
          source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n >> log2_qblk) << log2_qblk;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0 + lane; nn < n1; nn += NUM_THREADS) {
      const float v = fp16_to_float(load_src_value(
          src, K, N, k, nn, src_layout, log2_mt, log2_mxu_nt,
          source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other_min = shfl_down_float(min_v, offset);
    const float other_max = shfl_down_float(max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < min_v) min_v = other_min;
      if (other_max > max_v) max_v = other_max;
    }
  }
  min_v = shfl_idx_float(min_v, 0);
  max_v = shfl_idx_float(max_v, 0);
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const float abs_min = min_v < 0.0f ? -min_v : min_v;
    const float abs_max = max_v < 0.0f ? -max_v : max_v;
    const float absmax = abs_min > abs_max ? abs_min : abs_max;
    const float clamped_absmax = absmax < 1e-8f ? 1e-8f : absmax;
    *scale_out = clamped_absmax / 7.5f;
    *zero_out = 0.0f;
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
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *scale_out = scale;
    *zero_out = -8.0f - min_v / scale;
  } else {
    int32_t zp = kv_round_half_away_from_zero(-min_v * inv_for_zp);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
    *scale_out = scale;
    *zero_out = (float)zp;
  }
}

static uint8_t quant_at(const fp16_t* src,
                        uint32_t K,
                        uint32_t N,
                        uint32_t QBLK,
                        uint32_t QDIR,
                        uint32_t k,
                        uint32_t n,
                        uint32_t src_layout,
                        uint32_t log2_qblk,
                        uint32_t log2_mt,
                        uint32_t log2_mxu_nt,
                        uint32_t quant_mode,
                        const source_view_t& source_view) {
  if (k >= K || n >= N) {
    return 0;
  }
  float scale = 1.0f;
  float zero = 0.0f;
  compute_params(src, K, N, QBLK, QDIR, k, n, src_layout,
                 log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                 source_view, &scale, &zero);
  const float stored_scale = fp16_to_float(float_to_fp16(scale));
  const float quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? stored_scale : scale;
  const float value = fp16_to_float(load_src_value(src, K, N, k, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    const float inv_scale = (quant_scale == 0.0f) ? 0.0f : (1.0f / quant_scale);
    return kv_quantize_value_inv_scale(value, inv_scale, (int16_t)zero);
  }
  int32_t q = round_half_even(value / quant_scale + zero);
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

static uint8_t quant_with_params(const fp16_t* src,
                                 uint32_t K,
                                 uint32_t N,
                                 uint32_t k,
                                 uint32_t n,
                                 uint32_t src_layout,
                                 uint32_t log2_mt,
                                 uint32_t log2_mxu_nt,
                                 float scale,
                                 float zero,
                                 uint32_t quant_mode,
                                 const source_view_t& source_view) {
  if (k >= K || n >= N) {
    return 0;
  }
  const float value = fp16_to_float(load_src_value(src, K, N, k, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    const float inv_scale = (scale == 0.0f) ? 0.0f : (1.0f / scale);
    return kv_quantize_value_inv_scale(value, inv_scale, (int16_t)zero);
  }
  int32_t q = round_half_even(value / scale + zero);
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

static uint64_t weight_offset_wtrans0(uint32_t K,
                                      uint32_t N,
                                      uint32_t k,
                                      uint32_t n_pair,
                                      uint32_t log2_kt,
                                      uint32_t log2_mxu_kt,
                                      uint32_t log2_mxu_nt) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t kt = k >> log2_kt;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = min_u32(K - kt_start, kt_size);
  const uint32_t nt = (n_pair << 1) >> log2_mxu_nt;
  const uint32_t pair = n_pair & ((TILE_DMA_MXU_NT >> 1) - 1u);
  const uint32_t k_local = k - kt_start;
  const uint32_t kb = k_local >> log2_mxu_kt;
  const uint32_t k_in_sub = k_local & (mxu_kt - 1u);
  const uint32_t tid = (kb << log2_mxu_kt) + k_in_sub;
  return (uint64_t)kt * kt_size * row_bytes
       + (uint64_t)nt * ck * (mxu_nt >> 1)
       + (uint64_t)tid * (mxu_nt >> 1)
       + pair;
}

static uint64_t weight_offset_wtrans1(uint32_t K,
                                      uint32_t N,
                                      uint32_t k0,
                                      uint32_t n,
                                      uint32_t log2_kt,
                                      uint32_t log2_mxu_kt,
                                      uint32_t log2_mxu_nt) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
  const uint32_t kt = k0 >> log2_kt;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = min_u32(K - kt_start, kt_size);
  const uint32_t nt = n >> log2_mxu_nt;
  const uint32_t n_in_sub = n & (mxu_nt - 1u);
  const uint32_t k_local = k0 - kt_start;
  const uint32_t kb = k_local >> log2_mxu_kt;
  const uint32_t k_pair = (k_local & (mxu_kt - 1u)) >> 1;
  const uint32_t micro_bytes = mxu_nt * (mxu_kt >> 1);
  return (uint64_t)kt * kt_size * row_bytes
       + (uint64_t)nt * ck * (mxu_nt >> 1)
       + (uint64_t)kb * micro_bytes
       + (uint64_t)n_in_sub * (mxu_kt >> 1)
       + k_pair;
}

static uint8_t quant_source_at(const fp16_t* src,
                               uint32_t K,
                               uint32_t N,
                               uint32_t QBLK,
                               uint32_t QDIR,
                               uint32_t out_k,
                               uint32_t out_n,
                               uint32_t src_layout,
                               uint32_t log2_qblk,
                               uint32_t log2_mt,
                               uint32_t log2_mxu_nt,
                               uint32_t source_transposed,
                               uint32_t quant_mode,
                               const source_view_t& source_view) {
  const uint32_t source_row = source_transposed ? out_n : out_k;
  const uint32_t source_col = source_transposed ? out_k : out_n;
  if (source_row >= K || source_col >= N) {
    return 0;
  }
  return quant_at(src, K, N, QBLK, QDIR, source_row, source_col, src_layout,
                  log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                  source_view);
}

static uint32_t padded_weight_K(uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  return align_up_u32(logical,
                      logical <= DEFAULT_DMA_KT ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT);
}

static uint32_t padded_weight_N(uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  return align_up_u32(logical, TILE_DMA_MXU_NT);
}

static uint32_t padded_qparam_K(uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t GEMM_QDIR,
                                uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  uint32_t align = logical <= DEFAULT_DMA_KT ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT;
  if (GEMM_QDIR == 0 && QBLK > align) align = QBLK;
  return align_up_u32(logical, align);
}

static uint32_t padded_qparam_N(uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t GEMM_QDIR,
                                uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  uint32_t align = TILE_DMA_MXU_NT;
  if (GEMM_QDIR == 1 && QBLK > align) align = QBLK;
  return align_up_u32(logical, align);
}

static uint32_t scale_slot_body_bytes(uint32_t cur_k,
                                      uint32_t cur_n,
                                      uint32_t log2_qblk,
                                      uint32_t log2_mxu_nt,
                                      uint32_t log2_ng_per_mxu_nt,
                                      uint32_t QDIR) {
  const uint32_t ng_per_mxu_nt = 1u << log2_ng_per_mxu_nt;
  if (QDIR == 0) {
    return (cur_k >> log2_qblk) * cur_n * TILE_ELEM_BYTES;
  }
  return (cur_n >> log2_mxu_nt) * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
}

static uint64_t scale_slot_base(const kernel_arg_t* arg, uint32_t kt, uint32_t nt_dma) {
  const uint32_t slot_full_N = (kt + 1u == arg->k_tiles) ? arg->slot_pk_fn : arg->slot_fk_fn;
  return (uint64_t)kt * arg->per_kt_full_K + (uint64_t)nt_dma * slot_full_N;
}

static void store_u16(uint8_t* dst, uint64_t off, uint16_t value) {
  dst[off] = (uint8_t)(value & 0xffu);
  dst[off + 1] = (uint8_t)(value >> 8);
}

void kernel_kv_cache_quant_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto weight = reinterpret_cast<uint8_t *>(arg->weight_addr);
  auto scales = reinterpret_cast<uint8_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint8_t *>(arg->zero_addr);
  auto logical_scales = reinterpret_cast<fp16_t *>(arg->logical_scale_addr);
  auto logical_zeros = reinterpret_cast<fp16_t *>(arg->logical_zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t SOURCE_QDIR = arg->QDIR;
  const uint32_t GEMM_QDIR = arg->GEMM_QDIR;
  const uint32_t WTRANS = arg->WTRANS;
  const uint32_t src_layout = arg->src_layout;
  const uint32_t SOURCE_TRANSPOSED = arg->SOURCE_TRANSPOSED;
  const uint32_t quant_mode = arg->quant_mode;
  const source_view_t source_view = {
      arg->src_total_K == 0 ? K : arg->src_total_K,
      arg->src_total_N == 0 ? N : arg->src_total_N,
      arg->src_row_offset,
      arg->src_col_offset,
  };
  const uint32_t log2_mt = arg->log2_mt;
  const uint32_t log2_kt = arg->log2_kt;
  const uint32_t log2_nt = arg->log2_nt;
  const uint32_t log2_mxu_kt = arg->log2_mxu_kt;
  const uint32_t log2_mxu_nt = arg->log2_mxu_nt;
  const uint32_t log2_qblk = arg->log2_qblk;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t nt_size = 1u << log2_nt;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  const uint32_t weight_K = padded_weight_K(K, N, SOURCE_TRANSPOSED);
  const uint32_t weight_N = padded_weight_N(K, N, SOURCE_TRANSPOSED);
  const uint32_t weight_bytes = weight_K * (weight_N >> 1);
  if (SOURCE_TRANSPOSED != 0 && WTRANS != 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t logical_K = weight_K;
    const uint32_t logical_N = weight_N;
    const uint32_t source_groups = (logical_K + QBLK - 1u) >> log2_qblk;
    const uint32_t source_group_work = logical_N * source_groups;
    for (uint32_t work = thread_id; work < source_group_work; work += total_threads) {
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
      const uint32_t source_col_start = group << log2_qblk;
      const uint32_t source_col_end = min_u32(source_col_start + QBLK, logical_K);
      float scale = 1.0f;
      float zero = 0.0f;
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout,
                     log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
      const float stored_scale = fp16_to_float(float_to_fp16(scale));
      const float quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? stored_scale : scale;
      for (uint32_t source_col = source_col_start; source_col < source_col_end; source_col += 2) {
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        weight[weight_offset_wtrans1(logical_K, logical_N, source_col, source_row,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else if (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t source_groups = (weight_N + QBLK - 1u) >> log2_qblk;
    const uint32_t source_group_work = weight_K * source_groups;
    for (uint32_t work = thread_id; work < source_group_work; work += total_threads) {
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
      const uint32_t source_col_start = group << log2_qblk;
      const uint32_t source_col_end = min_u32(source_col_start + QBLK, weight_N);
      float scale = 1.0f;
      float zero = 0.0f;
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout,
                     log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
      const float stored_scale = fp16_to_float(float_to_fp16(scale));
      const float quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? stored_scale : scale;
      for (uint32_t source_col = source_col_start; source_col < source_col_end; source_col += 2) {
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        weight[weight_offset_wtrans0(weight_K, weight_N, source_row, source_col >> 1,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else {
    for (uint32_t i = thread_id; i < weight_bytes; i += total_threads) {
      if (SOURCE_TRANSPOSED != 0) {
        if (WTRANS == 0) continue;
        const uint32_t logical_K = weight_K;
        const uint32_t logical_N = weight_N;
        const uint32_t k0 = (i / logical_N) << 1;
        const uint32_t n = i - (k0 >> 1) * logical_N;
        const uint8_t q0 = quant_source_at(src, K, N, QBLK, SOURCE_QDIR, k0, n, src_layout,
                                           log2_qblk, log2_mt, log2_mxu_nt, 1,
                                           quant_mode, source_view);
        const uint8_t q1 = quant_source_at(src, K, N, QBLK, SOURCE_QDIR, k0 + 1, n, src_layout,
                                           log2_qblk, log2_mt, log2_mxu_nt, 1,
                                           quant_mode, source_view);
        weight[weight_offset_wtrans1(logical_K, logical_N, k0, n,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      } else if (WTRANS == 0) {
        const uint32_t k = i / (weight_N >> 1);
        const uint32_t n_pair = i - k * (weight_N >> 1);
        const uint32_t n0 = n_pair << 1;
        const uint8_t q0 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k, n0, src_layout,
                                    log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                                    source_view);
        const uint8_t q1 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k, n0 + 1, src_layout,
                                    log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                                    source_view);
        weight[weight_offset_wtrans0(weight_K, weight_N, k, n_pair,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      } else {
        const uint32_t k0 = (i / weight_N) << 1;
        const uint32_t n = i - (k0 >> 1) * weight_N;
        const uint8_t q0 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k0, n, src_layout,
                                    log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                                    source_view);
        const uint8_t q1 = quant_at(src, K, N, QBLK, SOURCE_QDIR, k0 + 1, n, src_layout,
                                    log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                                    source_view);
        weight[weight_offset_wtrans1(weight_K, weight_N, k0, n,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  }

  const uint32_t out_K = padded_qparam_K(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N(K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t max_slot_elems = arg->max_slot_bytes / TILE_ELEM_BYTES;
  const uint32_t qparam_work = arg->k_tiles * arg->n_dma_tiles * max_slot_elems;
#if KV_FUSED_QPARAM_WARP
  const uint32_t warp_slot = threadIdx.x / NUM_THREADS;
  const uint32_t lane = threadIdx.x - warp_slot * NUM_THREADS;
  const uint32_t warps_per_block = blockDim.x / NUM_THREADS;
  const uint32_t warp_id = blockIdx.x * warps_per_block + warp_slot;
  const uint32_t total_warps = gridDim.x * warps_per_block;
  for (uint32_t work = warp_id; work < qparam_work; work += total_warps) {
#else
  for (uint32_t work = thread_id; work < qparam_work; work += total_threads) {
#endif
    const uint32_t slot = work / max_slot_elems;
    const uint32_t elem_in_slot = work - slot * max_slot_elems;
    const uint32_t kt = slot / arg->n_dma_tiles;
    const uint32_t nt_dma = slot - kt * arg->n_dma_tiles;
    const uint32_t kt_start = kt << log2_kt;
    const uint32_t nt_start = nt_dma << log2_nt;
    const uint32_t cur_k = min_u32(out_K - kt_start, kt_size);
    const uint32_t cur_n = min_u32(out_N - nt_start, nt_size);
    const uint32_t body_bytes = scale_slot_body_bytes(cur_k, cur_n, log2_qblk,
                                                      log2_mxu_nt,
                                                      log2_ng_per_mxu_nt,
                                                      GEMM_QDIR);
    const uint32_t body_elems = body_bytes >> 1;
    const uint32_t slot_bytes = align_up_u32(body_bytes, TILE_SCALE_SLOT_ALIGN);
    const uint32_t byte_in_slot = elem_in_slot * TILE_ELEM_BYTES;
    if (byte_in_slot >= slot_bytes) {
      continue;
    }

    const uint64_t dst_off = scale_slot_base(arg, kt, nt_dma) + byte_in_slot;
    if (elem_in_slot >= body_elems) {
#if KV_FUSED_QPARAM_WARP
      if (lane == 0) {
#endif
      store_u16(scales, dst_off, 0);
      store_u16(zeros, dst_off, 0);
#if KV_FUSED_QPARAM_WARP
      }
#endif
      continue;
    }

    uint32_t param_k = kt_start;
    uint32_t param_n = nt_start;
    if (GEMM_QDIR == 0) {
      const uint32_t col = elem_in_slot & (TILE_DMA_MXU_NT - 1u);
      const uint32_t nb_g = elem_in_slot >> log2_mxu_nt;
      const uint32_t cur_groups = cur_k >> log2_qblk;
      uint32_t g;
      uint32_t nb;
      if (cur_k == kt_size) {
        const uint32_t log2_groups_per_kt = log2_kt - log2_qblk;
        g = nb_g & ((1u << log2_groups_per_kt) - 1u);
        nb = nb_g >> log2_groups_per_kt;
      } else {
        g = nb_g % cur_groups;
        nb = nb_g / cur_groups;
      }
      param_k = kt_start + (g << log2_qblk);
      param_n = nt_start + (nb << log2_mxu_nt) + col;
    } else {
      const uint32_t ng_per_mxu_nt = 1u << log2_ng_per_mxu_nt;
      const uint32_t ng_loc = elem_in_slot & (ng_per_mxu_nt - 1u);
      const uint32_t nb_k = elem_in_slot >> log2_ng_per_mxu_nt;
      uint32_t k_loc;
      uint32_t nb;
      if (cur_k == kt_size) {
        k_loc = nb_k & (kt_size - 1u);
        nb = nb_k >> log2_kt;
      } else {
        k_loc = nb_k % cur_k;
        nb = nb_k / cur_k;
      }
      const uint32_t mxu_per_dma_nt = nt_size >> log2_mxu_nt;
      const uint32_t global_nt_mxu = nt_dma * mxu_per_dma_nt + nb;
      const uint32_t global_ng = ((global_nt_mxu << log2_mxu_nt) >> log2_qblk) + ng_loc;
      param_k = kt_start + k_loc;
      param_n = global_ng << log2_qblk;
    }

    const uint32_t source_row = SOURCE_TRANSPOSED ? param_n : param_k;
    const uint32_t source_col = SOURCE_TRANSPOSED ? param_k : param_n;
    float scale = 1.0f;
    float zero = 0.0f;
#if KV_FUSED_QPARAM_WARP
    compute_params_warp(src, K, N, QBLK, SOURCE_QDIR,
                        source_row, source_col, src_layout,
                        log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                        source_view, lane,
                        &scale, &zero);
    if (lane == 0) {
#else
    compute_params(src, K, N, QBLK, SOURCE_QDIR,
                   source_row, source_col, src_layout,
                   log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                   source_view, &scale, &zero);
#endif
    store_u16(scales, dst_off, float_to_fp16(scale));
    store_u16(zeros, dst_off,
              quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
                  ? (uint16_t)zero : 0u);
#if KV_FUSED_QPARAM_WARP
    }
#endif
  }

  if (arg->logical_scale_addr != 0 && arg->logical_zero_addr != 0) {
    const uint32_t logical_groups = SOURCE_QDIR == 0
        ? ((K + QBLK - 1u) >> log2_qblk) * N
        : K * ((N + QBLK - 1u) >> log2_qblk);
    for (uint32_t group_index = thread_id; group_index < logical_groups;
         group_index += total_threads) {
      uint32_t source_row;
      uint32_t source_col;
      if (SOURCE_QDIR == 0) {
        source_row = (group_index / N) << log2_qblk;
        source_col = group_index % N;
      } else {
        const uint32_t groups_per_row = (N + QBLK - 1u) >> log2_qblk;
        source_row = group_index / groups_per_row;
        source_col = (group_index % groups_per_row) << log2_qblk;
      }
      float scale = 1.0f;
      float zero = 0.0f;
      compute_params(src, K, N, QBLK, SOURCE_QDIR, source_row, source_col,
                     src_layout, log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
      logical_scales[group_index] = float_to_fp16(scale);
      logical_zeros[group_index] = float_to_fp16(zero);
    }
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16:
      kernel_kv_cache_quant_layout_fused(arg);
      break;
    default:
      break;
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
