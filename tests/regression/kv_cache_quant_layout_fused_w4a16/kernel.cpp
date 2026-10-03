#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

#ifndef KV_FUSED_FP32_PARAMS
#define KV_FUSED_FP32_PARAMS 0
#endif

// The host reference follows the selected FP16 or FP32 parameter arithmetic.
#if KV_FUSED_FP32_PARAMS
using kv_fused_arith_t = float;
#else
using kv_fused_arith_t = _Float16;
#endif

#ifndef KV_FUSED_QPARAM_WARP
#define KV_FUSED_QPARAM_WARP 0
#endif

#ifndef KV_FUSED_PERSISTENT_WARP
#define KV_FUSED_PERSISTENT_WARP 0
#endif

#ifndef KV_FUSED_PREFILL_QPARAM_REUSE
#define KV_FUSED_PREFILL_QPARAM_REUSE 0
#endif

#ifndef KV_FUSED_FORCE_INLINE
#define KV_FUSED_FORCE_INLINE 0
#endif

#ifndef KV_FUSED_SOURCE_GROUP1_FAST
#define KV_FUSED_SOURCE_GROUP1_FAST 0
#endif

#ifndef KV_FUSED_PREFILL_TILED_CHUNK
#define KV_FUSED_PREFILL_TILED_CHUNK 0
#endif

#ifndef KV_FUSED_SOURCE_CURSOR
#define KV_FUSED_SOURCE_CURSOR 0
#endif

#ifndef KV_FUSED_POW2_WEIGHT_ADDR
#define KV_FUSED_POW2_WEIGHT_ADDR 0
#endif

#ifndef KV_FUSED_WEIGHT_CURSOR
#define KV_FUSED_WEIGHT_CURSOR 0
#endif

#ifndef KV_FUSED_WEIGHT_CURSOR_WTRANS0
#define KV_FUSED_WEIGHT_CURSOR_WTRANS0 KV_FUSED_WEIGHT_CURSOR
#endif

#ifndef KV_FUSED_WEIGHT_CURSOR_WTRANS1
#define KV_FUSED_WEIGHT_CURSOR_WTRANS1 KV_FUSED_WEIGHT_CURSOR
#endif

#ifndef KV_FUSED_SPLIT_PERSISTENT
#define KV_FUSED_SPLIT_PERSISTENT 0
#endif

#ifndef KV_FUSED_PREFILL_WARP_GROUP
#define KV_FUSED_PREFILL_WARP_GROUP 0
#endif

#if KV_FUSED_FORCE_INLINE
#define KV_FUSED_SMALL_HELPER static inline __attribute__((always_inline))
#define KV_FUSED_HELPER static inline __attribute__((always_inline))
#else
#define KV_FUSED_SMALL_HELPER static inline
#define KV_FUSED_HELPER static
#endif

KV_FUSED_SMALL_HELPER kv_fused_arith_t fused_arith_from_bits(fp16_t bits) {
#if KV_FUSED_FP32_PARAMS
  return fp16_to_float_preserve(bits);
#else
  return kv_fp16_from_bits(bits);
#endif
}

KV_FUSED_SMALL_HELPER fp16_t fused_arith_to_bits(kv_fused_arith_t value) {
#if KV_FUSED_FP32_PARAMS
  return float_to_fp16_preserve(value);
#else
  return kv_fp16_to_bits(value);
#endif
}

KV_FUSED_SMALL_HELPER uint16_t fused_zero_storage(kv_fused_arith_t zero) {
#if KV_FUSED_FP32_PARAMS
  return kv_tiled_zero_bits(fused_arith_to_bits(zero));
#else
  return (uint16_t)(int16_t)zero;
#endif
}

KV_FUSED_SMALL_HELPER uint32_t float_to_bits(kv_fused_arith_t value) {
  union { float f; uint32_t u; } v;
  v.f = (float)value;
  return v.u;
}

KV_FUSED_SMALL_HELPER kv_fused_arith_t bits_to_float(uint32_t value) {
  union { uint32_t u; float f; } v;
  v.u = value;
  return (kv_fused_arith_t)v.f;
}

KV_FUSED_SMALL_HELPER kv_fused_arith_t shfl_down_float(kv_fused_arith_t value, uint32_t offset) {
  return bits_to_float((uint32_t)vx_shfl_down(
      float_to_bits(value), offset, NUM_THREADS - 1, 0));
}

KV_FUSED_SMALL_HELPER kv_fused_arith_t shfl_idx_float(kv_fused_arith_t value, uint32_t index) {
  return bits_to_float((uint32_t)vx_shfl_idx(
      float_to_bits(value), index, NUM_THREADS - 1, 0));
}

KV_FUSED_SMALL_HELPER int32_t round_half_even(kv_fused_arith_t value) {
  const int32_t truncated = (int32_t)value;
  const kv_fused_arith_t truncated_f = (kv_fused_arith_t)truncated;
  const int32_t floor_value = truncated - (int32_t)(truncated_f > value);
  const kv_fused_arith_t fraction = value - (kv_fused_arith_t)floor_value;
  const int32_t round_up = (int32_t)(fraction > 0.5f)
      | ((int32_t)(fraction == 0.5f) & (floor_value & 1));
  return floor_value + round_up;
}

KV_FUSED_SMALL_HELPER kv_fused_arith_t spinquant_ratio(
    kv_fused_arith_t value, kv_fused_arith_t scale) {
#if KV_FUSED_FP32_PARAMS
  return value / scale;
#else
  return kv_spinquant_ratio_fp16(value, scale);
#endif
}

// Legacy uses a rounded stored scale; SpinQuant uses the selected precision.
KV_FUSED_HELPER int32_t legacy_zero(kv_fused_arith_t min_v,
                                    kv_fused_arith_t range,
                                    kv_fused_arith_t scale) {
#if KV_FUSED_FP32_PARAMS
  const float inv_for_zp = range != 0.0f ? 15.0f / range : 1.0f;
  return kv_round_half_away_from_zero(-min_v * inv_for_zp);
#else
  return kv_round_half_away_from_zero_fp16(-min_v / scale);
#endif
}

KV_FUSED_HELPER uint8_t quantize_legacy(kv_fused_arith_t value,
                                       kv_fused_arith_t scale,
                                       int16_t zero) {
#if KV_FUSED_FP32_PARAMS
  return kv_quantize_value_inv_scale(
      value, scale == 0.0f ? 0.0f : 1.0f / scale, zero);
#else
  return kv_quantize_value_scale_fp16(value, scale, zero);
#endif
}

KV_FUSED_HELPER uint32_t min_u32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

KV_FUSED_HELPER uint32_t align_up_u32(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

KV_FUSED_HELPER uint64_t gemm_c_tiled_offset(uint32_t K,
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

KV_FUSED_HELPER uint64_t gemm_a_tiled_offset(uint32_t K,
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

struct source_row_cursor_t {
  const fp16_t* src;
  uint64_t offset;
  uint32_t logical_col;
  uint32_t logical_n;
  uint32_t within_tile;
  uint32_t tile_mask;
  uint32_t tile_advance;
  bool valid_row;
};

KV_FUSED_HELPER source_row_cursor_t make_source_row_cursor(
    const fp16_t* src,
    uint32_t K,
    uint32_t N,
    uint32_t k,
    uint32_t n,
    uint32_t src_layout,
    uint32_t log2_mt,
    uint32_t log2_mxu_nt,
    const source_view_t& source_view) {
  source_row_cursor_t cursor;
  cursor.src = src;
  cursor.offset = 0;
  cursor.logical_col = n;
  cursor.logical_n = N;
  cursor.within_tile = 0;
  cursor.tile_mask = 0xffffffffu;
  cursor.tile_advance = 0;
  cursor.valid_row = k < K;
  if (!cursor.valid_row) {
    return cursor;
  }

  const uint32_t physical_k = k + source_view.row_offset;
  const uint32_t physical_n = n + source_view.col_offset;
  if (src_layout == SRC_LAYOUT_GEMM_C_TILED
      || src_layout == SRC_LAYOUT_GEMM_A_TILED) {
    const uint32_t mt_size = 1u << log2_mt;
    const uint32_t mt = physical_k >> log2_mt;
    const uint32_t m0 = physical_k & (mt_size - 1u);
    const uint32_t cm =
        min_u32(source_view.total_k - (mt << log2_mt), mt_size);
    const uint32_t tile_size = 1u << log2_mxu_nt;
    const uint32_t tile_mask = tile_size - 1u;
    const uint32_t tile = physical_n >> log2_mxu_nt;
    cursor.offset = (uint64_t)mt * mt_size * source_view.total_n
                  + (uint64_t)tile * cm * tile_size
                  + (uint64_t)m0 * tile_size
                  + (physical_n & tile_mask);
    cursor.within_tile = physical_n & tile_mask;
    cursor.tile_mask = tile_mask;
    cursor.tile_advance = (cm - 1u) * tile_size;
    return cursor;
  }

  cursor.offset =
      (uint64_t)physical_k * source_view.total_n + physical_n;
  cursor.within_tile = physical_n;
  return cursor;
}

KV_FUSED_HELPER fp16_t source_row_cursor_next(
    source_row_cursor_t* cursor,
    bool* valid) {
  *valid = cursor->valid_row && cursor->logical_col < cursor->logical_n;
  const fp16_t value = *valid ? cursor->src[cursor->offset] : 0;
  ++cursor->logical_col;
  ++cursor->offset;
  cursor->within_tile = (cursor->within_tile + 1u) & cursor->tile_mask;
  if (cursor->within_tile == 0) {
    cursor->offset += cursor->tile_advance;
  }
  return value;
}

KV_FUSED_HELPER fp16_t load_src_value(const fp16_t* src,
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

#if KV_FUSED_SOURCE_CURSOR
KV_FUSED_HELPER void compute_params_qdir1_cursor(
    const fp16_t* src,
    uint32_t K,
    uint32_t N,
    uint32_t QBLK,
    uint32_t k,
    uint32_t n,
    uint32_t src_layout,
    uint32_t log2_qblk,
    uint32_t log2_mt,
    uint32_t log2_mxu_nt,
    uint32_t quant_mode,
    const source_view_t& source_view,
    kv_fused_arith_t* scale_out,
    kv_fused_arith_t* zero_out) {
  if (k >= K || n >= N) {
    *scale_out = 0.0f;
    *zero_out = 0.0f;
    return;
  }

  const uint32_t n0 = (n >> log2_qblk) << log2_qblk;
  const uint32_t n1 = min_u32(n0 + QBLK, N);
  source_row_cursor_t cursor = make_source_row_cursor(
      src, K, N, k, n0, src_layout, log2_mt, log2_mxu_nt, source_view);
  kv_fused_arith_t min_v;
  kv_fused_arith_t max_v;
  kv_fused_arith_t absmax;
#if KV_FUSED_PREFILL_TILED_CHUNK
  const uint32_t tile_size = 1u << log2_mxu_nt;
  if (cursor.within_tile == 0u && cursor.tile_mask == tile_size - 1u
      && ((n1 - n0) & (tile_size - 1u)) == 0u) {
    const fp16_t* tile = src + cursor.offset;
    min_v = fused_arith_from_bits(tile[0]);
    max_v = min_v;
    absmax = min_v < 0.0f ? -min_v : min_v;
    for (uint32_t start = n0; start < n1; start += tile_size) {
      for (uint32_t col = 0; col < tile_size; ++col) {
        const kv_fused_arith_t v = fused_arith_from_bits(tile[col]);
        if (v < min_v) min_v = v;
        if (v > max_v) max_v = v;

      }
      tile += cursor.tile_advance + tile_size;
    }
  } else
#endif
  {
    bool valid = false;
    min_v = fused_arith_from_bits(source_row_cursor_next(&cursor, &valid));
    max_v = min_v;
    absmax = min_v < 0.0f ? -min_v : min_v;
    for (uint32_t nn = n0 + 1u; nn < n1; ++nn) {
      const kv_fused_arith_t v = fused_arith_from_bits(source_row_cursor_next(&cursor, &valid));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
#if !KV_FUSED_PREFILL_TILED_CHUNK
      const kv_fused_arith_t abs_v = v < 0.0f ? -v : v;
      if (abs_v > absmax) absmax = abs_v;
#endif
    }
  }

#if KV_FUSED_PREFILL_TILED_CHUNK
  const kv_fused_arith_t abs_min = min_v < 0.0f ? -min_v : min_v;
  const kv_fused_arith_t abs_max = max_v < 0.0f ? -max_v : max_v;
  absmax = abs_min > abs_max ? abs_min : abs_max;
#endif
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    if (absmax < 1e-8f) absmax = 1e-8f;
    *scale_out = absmax / 7.5f;
    *zero_out = 0.0f;
    return;
  }

  const kv_fused_arith_t range = max_v - min_v;
  kv_fused_arith_t scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
  }
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)round_half_even(spinquant_ratio(-min_v, scale)) - 8.0f;
  } else {
    int32_t zp = legacy_zero(min_v, range, scale);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)zp;
  }
}
#endif

KV_FUSED_HELPER void compute_params(const fp16_t* src,
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
                           kv_fused_arith_t* scale_out,
                           kv_fused_arith_t* zero_out) {
  if (k >= K || n >= N) {
    *scale_out = 0.0f;
    *zero_out = 0.0f;
    return;
  }
  kv_fused_arith_t min_v = fused_arith_from_bits(load_src_value(src, K, N, k, n, src_layout,
                                             log2_mt, log2_mxu_nt,
                                             source_view));
  kv_fused_arith_t max_v = min_v;
  kv_fused_arith_t absmax = min_v < 0.0f ? -min_v : min_v;

  if (QDIR == 0) {
    const uint32_t k0 = (k >> log2_qblk) << log2_qblk;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const kv_fused_arith_t v = fused_arith_from_bits(load_src_value(src, K, N, kk, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
      const kv_fused_arith_t abs_v = v < 0.0f ? -v : v;
      if (abs_v > absmax) absmax = abs_v;
    }
  } else {
    const uint32_t n0 = (n >> log2_qblk) << log2_qblk;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const kv_fused_arith_t v = fused_arith_from_bits(load_src_value(src, K, N, k, nn, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
      const kv_fused_arith_t abs_v = v < 0.0f ? -v : v;
      if (abs_v > absmax) absmax = abs_v;
    }
  }

  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    if (absmax < 1e-8f) absmax = 1e-8f;
    *scale_out = absmax / 7.5f;
    *zero_out = 0.0f;
    return;
  }

  const kv_fused_arith_t range = max_v - min_v;
  kv_fused_arith_t scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
  }
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)round_half_even(spinquant_ratio(-min_v, scale)) - 8.0f;
  } else {
    int32_t zp = legacy_zero(min_v, range, scale);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)zp;
  }
}

KV_FUSED_HELPER void make_warp_qparams(kv_fused_arith_t min_v,
                                      kv_fused_arith_t max_v,
                                      uint32_t quant_mode,
                                      kv_fused_arith_t* scale_out,
                                      kv_fused_arith_t* zero_out) {
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const kv_fused_arith_t abs_min = min_v < 0.0f ? -min_v : min_v;
    const kv_fused_arith_t abs_max = max_v < 0.0f ? -max_v : max_v;
    const kv_fused_arith_t absmax = abs_min > abs_max ? abs_min : abs_max;
    const kv_fused_arith_t clamped_absmax = absmax < 1e-8f ? 1e-8f : absmax;
    *scale_out = clamped_absmax / 7.5f;
    *zero_out = 0.0f;
    return;
  }
  const kv_fused_arith_t range = max_v - min_v;
  kv_fused_arith_t scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
  }
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)round_half_even(spinquant_ratio(-min_v, scale)) - 8.0f;
  } else {
    int32_t zp = legacy_zero(min_v, range, scale);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
    *scale_out = scale;
    *zero_out = (kv_fused_arith_t)zp;
  }
}

KV_FUSED_HELPER void compute_params_warp(const fp16_t* src,
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
                                kv_fused_arith_t* scale_out,
                                kv_fused_arith_t* zero_out) {
  if (k >= K || n >= N) {
    *scale_out = 0.0f;
    *zero_out = 0.0f;
    return;
  }
  kv_fused_arith_t min_v = fused_arith_from_bits(load_src_value(
      src, K, N, k, n, src_layout, log2_mt, log2_mxu_nt, source_view));
  kv_fused_arith_t max_v = min_v;
  if (QDIR == 0) {
    const uint32_t k0 = (k >> log2_qblk) << log2_qblk;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0 + lane; kk < k1; kk += NUM_THREADS) {
      const kv_fused_arith_t v = fused_arith_from_bits(load_src_value(
          src, K, N, kk, n, src_layout, log2_mt, log2_mxu_nt,
          source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n >> log2_qblk) << log2_qblk;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0 + lane; nn < n1; nn += NUM_THREADS) {
      const kv_fused_arith_t v = fused_arith_from_bits(load_src_value(
          src, K, N, k, nn, src_layout, log2_mt, log2_mxu_nt,
          source_view));
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const kv_fused_arith_t other_min = shfl_down_float(min_v, offset);
    const kv_fused_arith_t other_max = shfl_down_float(max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < min_v) min_v = other_min;
      if (other_max > max_v) max_v = other_max;
    }
  }
  min_v = shfl_idx_float(min_v, 0);
  max_v = shfl_idx_float(max_v, 0);
  make_warp_qparams(min_v, max_v, quant_mode, scale_out, zero_out);
}

KV_FUSED_HELPER uint8_t quant_at(const fp16_t* src,
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
  kv_fused_arith_t scale = 1.0f;
  kv_fused_arith_t zero = 0.0f;
  compute_params(src, K, N, QBLK, QDIR, k, n, src_layout,
                 log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                 source_view, &scale, &zero);
  const kv_fused_arith_t stored_scale = fused_arith_from_bits(fused_arith_to_bits(scale));
  const kv_fused_arith_t quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? stored_scale : scale;
  const kv_fused_arith_t value = fused_arith_from_bits(load_src_value(src, K, N, k, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return quantize_legacy(value, quant_scale, (int16_t)zero);
  }
  int32_t q = round_half_even(KV_FUSED_FP32_PARAMS
      ? value * (1.0f / quant_scale)
      : spinquant_ratio(value, quant_scale)) + (int32_t)zero;
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

KV_FUSED_HELPER uint8_t quant_with_params(const fp16_t* src,
                                 uint32_t K,
                                 uint32_t N,
                                 uint32_t k,
                                 uint32_t n,
                                 uint32_t src_layout,
                                 uint32_t log2_mt,
                                 uint32_t log2_mxu_nt,
                                 kv_fused_arith_t scale,
                                 kv_fused_arith_t zero,
                                 uint32_t quant_mode,
                                 const source_view_t& source_view) {
  if (k >= K || n >= N) {
    return 0;
  }
  const kv_fused_arith_t value = fused_arith_from_bits(load_src_value(src, K, N, k, n, src_layout,
                                                   log2_mt, log2_mxu_nt,
                                                   source_view));
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return quantize_legacy(value, scale, (int16_t)zero);
  }
  int32_t q = round_half_even(KV_FUSED_FP32_PARAMS
      ? value * (1.0f / scale)
      : spinquant_ratio(value, scale)) + (int32_t)zero;
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

KV_FUSED_HELPER uint8_t quantize_loaded_value(fp16_t value_bits,
                                             kv_fused_arith_t scale,
                                             kv_fused_arith_t zero,
                                             uint32_t quant_mode) {
  const kv_fused_arith_t value = fused_arith_from_bits(value_bits);
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return quantize_legacy(value, scale, (int16_t)zero);
  }
  int32_t q = round_half_even(KV_FUSED_FP32_PARAMS
      ? value * (1.0f / scale)
      : spinquant_ratio(value, scale)) + (int32_t)zero;
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

KV_FUSED_HELPER uint64_t weight_offset_wtrans0(uint32_t K,
                                      uint32_t N,
                                      uint32_t k,
                                      uint32_t n_pair,
                                      uint32_t log2_kt,
                                      uint32_t log2_mxu_kt,
                                      uint32_t log2_mxu_nt) {
  const uint32_t row_bytes = N >> 1;
  const uint32_t kt_size = 1u << log2_kt;
#if !KV_FUSED_POW2_WEIGHT_ADDR
  const uint32_t mxu_kt = 1u << log2_mxu_kt;
  const uint32_t mxu_nt = 1u << log2_mxu_nt;
#endif
  const uint32_t kt = k >> log2_kt;
  const uint32_t kt_start = kt << log2_kt;
  const uint32_t ck = min_u32(K - kt_start, kt_size);
  const uint32_t nt = (n_pair << 1) >> log2_mxu_nt;
  const uint32_t pair = n_pair & ((TILE_DMA_MXU_NT >> 1) - 1u);
  const uint32_t k_local = k - kt_start;
#if KV_FUSED_POW2_WEIGHT_ADDR
  const uint64_t nt_rows = ck == kt_size
      ? ((uint64_t)nt << log2_kt)
      : (uint64_t)nt * ck;
  return (uint64_t)kt_start * row_bytes
       + (nt_rows << (log2_mxu_nt - 1u))
       + ((uint64_t)k_local << (log2_mxu_nt - 1u))
       + pair;
#else
  const uint32_t kb = k_local >> log2_mxu_kt;
  const uint32_t k_in_sub = k_local & (mxu_kt - 1u);
  const uint32_t tid = (kb << log2_mxu_kt) + k_in_sub;
  return (uint64_t)kt * kt_size * row_bytes
       + (uint64_t)nt * ck * (mxu_nt >> 1)
       + (uint64_t)tid * (mxu_nt >> 1)
       + pair;
#endif
}

KV_FUSED_HELPER uint64_t weight_offset_wtrans1(uint32_t K,
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
#if KV_FUSED_POW2_WEIGHT_ADDR
  const uint64_t nt_rows = ck == kt_size
      ? ((uint64_t)nt << log2_kt)
      : (uint64_t)nt * ck;
  return (uint64_t)kt_start * row_bytes
       + (nt_rows << (log2_mxu_nt - 1u))
       + ((uint64_t)kb
          << (log2_mxu_nt + log2_mxu_kt - 1u))
       + ((uint64_t)n_in_sub << (log2_mxu_kt - 1u))
       + k_pair;
#else
  const uint32_t micro_bytes = mxu_nt * (mxu_kt >> 1);
  return (uint64_t)kt * kt_size * row_bytes
       + (uint64_t)nt * ck * (mxu_nt >> 1)
       + (uint64_t)kb * micro_bytes
       + (uint64_t)n_in_sub * (mxu_kt >> 1)
       + k_pair;
#endif
}

#if KV_FUSED_WEIGHT_CURSOR_WTRANS0 || KV_FUSED_WEIGHT_CURSOR_WTRANS1
struct weight_wtrans0_cursor_t {
  uint32_t K;
  uint32_t N;
  uint32_t k;
  uint32_t n_pair;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint64_t offset;
};

KV_FUSED_HELPER weight_wtrans0_cursor_t make_weight_wtrans0_cursor(
    uint32_t K,
    uint32_t N,
    uint32_t k,
    uint32_t n_pair,
    uint32_t log2_kt,
    uint32_t log2_mxu_kt,
    uint32_t log2_mxu_nt) {
  weight_wtrans0_cursor_t cursor = {
      K, N, k, n_pair, log2_kt, log2_mxu_kt, log2_mxu_nt,
      weight_offset_wtrans0(
          K, N, k, n_pair, log2_kt, log2_mxu_kt, log2_mxu_nt)};
  return cursor;
}

KV_FUSED_HELPER uint64_t weight_wtrans0_cursor_next(
    weight_wtrans0_cursor_t* cursor) {
  const uint64_t offset = cursor->offset;
  ++cursor->n_pair;
  if (((cursor->n_pair << 1u)
       & ((1u << cursor->log2_mxu_nt) - 1u)) != 0) {
    ++cursor->offset;
  } else {
    cursor->offset = weight_offset_wtrans0(
        cursor->K, cursor->N, cursor->k, cursor->n_pair,
        cursor->log2_kt, cursor->log2_mxu_kt, cursor->log2_mxu_nt);
  }
  return offset;
}

struct weight_wtrans1_cursor_t {
  uint32_t K;
  uint32_t N;
  uint32_t k0;
  uint32_t n;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint64_t offset;
};

KV_FUSED_HELPER weight_wtrans1_cursor_t make_weight_wtrans1_cursor(
    uint32_t K,
    uint32_t N,
    uint32_t k0,
    uint32_t n,
    uint32_t log2_kt,
    uint32_t log2_mxu_kt,
    uint32_t log2_mxu_nt) {
  weight_wtrans1_cursor_t cursor = {
      K, N, k0, n, log2_kt, log2_mxu_kt, log2_mxu_nt,
      weight_offset_wtrans1(
          K, N, k0, n, log2_kt, log2_mxu_kt, log2_mxu_nt)};
  return cursor;
}

KV_FUSED_HELPER uint64_t weight_wtrans1_cursor_next(
    weight_wtrans1_cursor_t* cursor) {
  const uint64_t offset = cursor->offset;
  cursor->k0 += 2u;
  if ((cursor->k0 & ((1u << cursor->log2_mxu_kt) - 1u)) != 0) {
    ++cursor->offset;
  } else {
    cursor->offset = weight_offset_wtrans1(
        cursor->K, cursor->N, cursor->k0, cursor->n,
        cursor->log2_kt, cursor->log2_mxu_kt, cursor->log2_mxu_nt);
  }
  return offset;
}
#endif

KV_FUSED_HELPER uint8_t quant_source_at(const fp16_t* src,
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

KV_FUSED_HELPER uint32_t padded_weight_K(
    uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  return align_up_u32(logical,
                      logical <= DEFAULT_DMA_KT ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT);
}

KV_FUSED_HELPER uint32_t padded_weight_N(
    uint32_t K, uint32_t N, uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  return align_up_u32(logical, TILE_DMA_MXU_NT);
}

KV_FUSED_HELPER uint32_t padded_qparam_K(uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t GEMM_QDIR,
                                uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  uint32_t align = logical <= DEFAULT_DMA_KT ? TILE_DMA_MXU_KT : DEFAULT_DMA_KT;
  if (GEMM_QDIR == 0 && QBLK > align) align = QBLK;
  return align_up_u32(logical, align);
}

KV_FUSED_HELPER uint32_t padded_qparam_N(uint32_t K,
                                uint32_t N,
                                uint32_t QBLK,
                                uint32_t GEMM_QDIR,
                                uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? K : N;
  uint32_t align = TILE_DMA_MXU_NT;
  if (GEMM_QDIR == 1 && QBLK > align) align = QBLK;
  return align_up_u32(logical, align);
}

KV_FUSED_HELPER uint32_t scale_slot_body_bytes(uint32_t cur_k,
                                      uint32_t cur_n,
                                      uint32_t log2_qblk,
                                      uint32_t log2_mxu_nt,
                                      uint32_t log2_ng_per_mxu_nt,
                                      uint32_t QDIR) {
  const uint32_t ng_per_mxu_nt = 1u << log2_ng_per_mxu_nt;
  if (QDIR == 0) {
    const uint32_t qblk = 1u << log2_qblk;
    return ((cur_k + qblk - 1u) >> log2_qblk) * cur_n * TILE_ELEM_BYTES;
  }
  return (cur_n >> log2_mxu_nt) * cur_k * ng_per_mxu_nt * TILE_ELEM_BYTES;
}

KV_FUSED_HELPER uint64_t scale_slot_base(
    const kernel_arg_t* arg, uint32_t kt, uint32_t nt_dma) {
  const uint32_t slot_full_N = (kt + 1u == arg->k_tiles) ? arg->slot_pk_fn : arg->slot_fk_fn;
  return (uint64_t)kt * arg->per_kt_full_K + (uint64_t)nt_dma * slot_full_N;
}

KV_FUSED_HELPER void store_u16(uint8_t* dst, uint64_t off, uint16_t value) {
  // Tiled qparam offsets and slot bases are aligned to two bytes.
  *reinterpret_cast<uint16_t*>(dst + off) = value;
}

#if KV_FUSED_PREFILL_TILED_CHUNK
KV_FUSED_SMALL_HELPER
#else
__attribute__((noinline)) static
#endif
void store_reused_tiled_qparam(const kernel_arg_t* arg,
                                      uint8_t* scales,
                                      uint8_t* zeros,
                                      uint32_t K,
                                      uint32_t N,
                                      uint32_t QBLK,
                                      uint32_t GEMM_QDIR,
                                      uint32_t SOURCE_TRANSPOSED,
                                      uint32_t quant_mode,
                                      uint32_t source_row,
                                      uint32_t source_col,
                                      kv_fused_arith_t scale,
                                      kv_fused_arith_t zero) {
  const uint32_t out_K = padded_qparam_K(
      K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t out_N = padded_qparam_N(
      K, N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
  const uint32_t log2_kt = arg->log2_kt;
  const uint32_t log2_nt = arg->log2_nt;
  const uint32_t log2_mxu_nt = arg->log2_mxu_nt;
  const uint32_t log2_qblk = arg->log2_qblk;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t param_k =
      SOURCE_TRANSPOSED != 0 ? source_col : source_row;
  const uint32_t param_n =
      SOURCE_TRANSPOSED != 0 ? source_row : source_col;
  const uint32_t n_replicas =
      GEMM_QDIR == 1 && QBLK > TILE_DMA_MXU_NT
          ? QBLK >> log2_mxu_nt
          : 1u;
  const uint16_t scale_bits = fused_arith_to_bits(scale);
  const uint16_t zero_bits =
      quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
          ? 0u
          : fused_zero_storage(zero);

#if KV_FUSED_PREFILL_TILED_CHUNK
  if (SOURCE_TRANSPOSED != 0 && GEMM_QDIR == 0
      && out_K <= kt_size && QBLK >= out_K && source_col == 0u) {
    // Each DMA N tile has its own aligned slot, including trailing padding.
    const uint32_t nt_dma = source_row >> log2_nt;
    const uint32_t n_local = source_row & ((1u << log2_nt) - 1u);
    const uint64_t offset = scale_slot_base(arg, 0u, nt_dma)
        + (uint64_t)n_local * TILE_ELEM_BYTES;
    store_u16(scales, offset, scale_bits);
    store_u16(zeros, offset, zero_bits);
    return;
  }
  if (SOURCE_TRANSPOSED == 0 && GEMM_QDIR == 1
      && QBLK >= TILE_DMA_MXU_NT && QBLK <= (1u << log2_nt)
      && param_k < out_K && param_n + QBLK <= out_N) {
    const uint32_t kt = param_k >> log2_kt;
    const uint32_t nt_dma = param_n >> log2_nt;
    const uint32_t cur_k = min_u32(out_K - (kt << log2_kt), kt_size);
    const uint32_t nb = (param_n - (nt_dma << log2_nt)) >> log2_mxu_nt;
    const uint32_t k_local = param_k & (kt_size - 1u);
    const uint64_t offset = scale_slot_base(arg, kt, nt_dma)
        + (uint64_t)(nb * cur_k + k_local) * TILE_ELEM_BYTES;
    auto scale_cursor = reinterpret_cast<uint16_t*>(scales + offset);
    auto zero_cursor = reinterpret_cast<uint16_t*>(zeros + offset);
    for (uint32_t replica = 0; replica < n_replicas; ++replica) {
      *scale_cursor = scale_bits;
      *zero_cursor = zero_bits;
      scale_cursor += cur_k;
      zero_cursor += cur_k;
    }
    return;
  }
#endif

  for (uint32_t replica = 0; replica < n_replicas; ++replica) {
    const uint32_t dst_param_n =
        param_n + (replica << log2_mxu_nt);
    if (param_k >= out_K || dst_param_n >= out_N) {
      continue;
    }

    const uint32_t kt = param_k >> log2_kt;
    const uint32_t nt_dma = dst_param_n >> log2_nt;
    const uint32_t kt_start = kt << log2_kt;
    const uint32_t nt_start = nt_dma << log2_nt;
    const uint32_t cur_k = min_u32(out_K - kt_start, kt_size);
    uint32_t elem_in_slot;
    if (GEMM_QDIR == 0) {
      const uint32_t cur_groups =
          (cur_k + (1u << log2_qblk) - 1u) >> log2_qblk;
      const uint32_t group = (param_k - kt_start) >> log2_qblk;
      const uint32_t local_n = dst_param_n - nt_start;
      const uint32_t nb = local_n >> log2_mxu_nt;
      const uint32_t col =
          local_n & (TILE_DMA_MXU_NT - 1u);
      elem_in_slot =
          ((nb * cur_groups + group) << log2_mxu_nt) + col;
    } else {
      const uint32_t k_local = param_k - kt_start;
      const uint32_t local_n = dst_param_n - nt_start;
      const uint32_t nb = local_n >> log2_mxu_nt;
      const uint32_t ng_local =
          (local_n & (TILE_DMA_MXU_NT - 1u)) >> log2_qblk;
      elem_in_slot =
          ((nb * cur_k + k_local) << log2_ng_per_mxu_nt) + ng_local;
    }

    const uint64_t dst_off =
        scale_slot_base(arg, kt, nt_dma)
        + (uint64_t)elem_in_slot * TILE_ELEM_BYTES;
    store_u16(scales, dst_off, scale_bits);
    store_u16(zeros, dst_off, zero_bits);
  }
}

template <bool Reuse>
__attribute__((noinline))
static void store_prefill_qparams(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto scales = reinterpret_cast<uint8_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint8_t *>(arg->zero_addr);
  auto logical_scales = reinterpret_cast<fp16_t *>(arg->logical_scale_addr);
  auto logical_zeros = reinterpret_cast<fp16_t *>(arg->logical_zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t SOURCE_QDIR = arg->QDIR;
  const uint32_t GEMM_QDIR = arg->GEMM_QDIR;
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
  const uint32_t log2_mxu_nt = arg->log2_mxu_nt;
  const uint32_t log2_qblk = arg->log2_qblk;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t nt_size = 1u << log2_nt;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

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
    if (Reuse) {
      continue;
    }

    uint32_t param_k = kt_start;
    uint32_t param_n = nt_start;
    if (GEMM_QDIR == 0) {
      const uint32_t col = elem_in_slot & (TILE_DMA_MXU_NT - 1u);
      const uint32_t nb_g = elem_in_slot >> log2_mxu_nt;
      const uint32_t cur_groups =
          (cur_k + (1u << log2_qblk) - 1u) >> log2_qblk;
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
    kv_fused_arith_t scale = 1.0f;
    kv_fused_arith_t zero = 0.0f;
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
    store_u16(scales, dst_off, fused_arith_to_bits(scale));
    store_u16(zeros, dst_off,
              quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
                  ? 0u : fused_zero_storage(zero));
#if KV_FUSED_QPARAM_WARP
    }
#endif
  }

  if (!Reuse
      && arg->logical_scale_addr != 0
      && arg->logical_zero_addr != 0) {
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
      kv_fused_arith_t scale = 1.0f;
      kv_fused_arith_t zero = 0.0f;
      compute_params(src, K, N, QBLK, SOURCE_QDIR, source_row, source_col,
                     src_layout, log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
      logical_scales[group_index] = fused_arith_to_bits(scale);
      logical_zeros[group_index] = fused_arith_to_bits(zero);
    }
  }
}

struct cross_qparams_t {
  kv_fused_arith_t scale;
  kv_fused_arith_t zero;
};

template <bool AlongN, bool RowMajor>
__attribute__((noinline))
static cross_qparams_t compute_cross_qparams(kernel_arg_t *__UNIFORM__ arg,
                                            uint32_t k, uint32_t n) {
  const source_view_t view = {
      arg->src_total_K == 0 ? arg->K : arg->src_total_K,
      arg->src_total_N == 0 ? arg->N : arg->src_total_N,
      arg->src_row_offset, arg->src_col_offset};
  cross_qparams_t result;
  compute_params_warp(reinterpret_cast<fp16_t*>(arg->src_addr),
      arg->K, arg->N, arg->QBLK, AlongN ? 1u : 0u, k, n,
      RowMajor ? SRC_LAYOUT_ROW_MAJOR : arg->src_layout,
      arg->log2_qblk, arg->log2_mt, __builtin_ctz(TILE_DMA_MXU_NT),
      arg->quant_mode, view, threadIdx.x % NUM_THREADS,
      &result.scale, &result.zero);
  return result;
}

__attribute__((noinline))
static void store_cross_qparams(kernel_arg_t *__UNIFORM__ arg,
                               uint32_t k, uint32_t n,
                               kv_fused_arith_t scale, kv_fused_arith_t zero) {
  const uint32_t lane = threadIdx.x % NUM_THREADS;
  if (arg->GEMM_QDIR == 1u && arg->QBLK >= TILE_DMA_MXU_NT) {
    const uint32_t out_K = padded_qparam_K(arg->K, arg->N, arg->QBLK, 1u, 0u);
    const uint32_t out_N = padded_qparam_N(arg->K, arg->N, arg->QBLK, 1u, 0u);
    const uint32_t kt = k >> arg->log2_kt;
    const uint32_t cur_k = min_u32(out_K - (kt << arg->log2_kt), 1u << arg->log2_kt);
    const uint32_t row = k & ((1u << arg->log2_kt) - 1u);
    const uint32_t replicas = arg->QBLK >> __builtin_ctz(TILE_DMA_MXU_NT);
    for (uint32_t replica = lane; replica < replicas; replica += NUM_THREADS) {
      const uint32_t col = n + replica * TILE_DMA_MXU_NT;
      if (k >= out_K || col >= out_N) continue;
      const uint32_t nt = col >> arg->log2_nt;
      const uint32_t nb = (col & ((1u << arg->log2_nt) - 1u)) >> __builtin_ctz(TILE_DMA_MXU_NT);
      const uint64_t offset = scale_slot_base(arg, kt, nt)
          + (uint64_t)(nb * cur_k + row) * TILE_ELEM_BYTES;
      store_u16(reinterpret_cast<uint8_t*>(arg->scale_addr), offset, fused_arith_to_bits(scale));
      store_u16(reinterpret_cast<uint8_t*>(arg->zero_addr), offset,
          arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC ? 0u : fused_zero_storage(zero));
    }
  } else if (lane == 0u) {
    store_reused_tiled_qparam(arg, reinterpret_cast<uint8_t*>(arg->scale_addr),
        reinterpret_cast<uint8_t*>(arg->zero_addr), arg->K, arg->N, arg->QBLK,
        arg->GEMM_QDIR, 0, arg->quant_mode, k, n, scale, zero);
  }
}

__attribute__((noinline))
static cross_qparams_t compute_row_qparams(kernel_arg_t *__UNIFORM__ arg,
                                          uint32_t row, uint32_t col) {
  cross_qparams_t result = {};
  if (row >= arg->K || col >= arg->N) return result;
  const uint32_t source_N = arg->src_total_N == 0u ? arg->N : arg->src_total_N;
  auto src = reinterpret_cast<fp16_t*>(arg->src_addr)
      + (uint64_t)(row + arg->src_row_offset) * source_N + arg->src_col_offset;
  kv_fused_arith_t min_v = fused_arith_from_bits(src[col]);
  kv_fused_arith_t max_v = min_v;
  const uint32_t end = min_u32(col + arg->QBLK, arg->N);
  for (uint32_t n = col + 1u; n < end; ++n) {
    const kv_fused_arith_t value = fused_arith_from_bits(src[n]);
    if (value < min_v) min_v = value;
    if (value > max_v) max_v = value;
  }
  make_warp_qparams(min_v, max_v, arg->quant_mode, &result.scale, &result.zero);
  return result;
}

__attribute__((noinline))
static void store_row_qparams(kernel_arg_t *__UNIFORM__ arg,
                             uint32_t row, uint32_t col,
                             kv_fused_arith_t scale, kv_fused_arith_t zero) {
  const uint32_t out_K = padded_qparam_K(arg->K, arg->N, arg->QBLK, 1u, 0u);
  const uint32_t out_N = padded_qparam_N(arg->K, arg->N, arg->QBLK, 1u, 0u);
  const uint32_t kt = row >> arg->log2_kt;
  const uint32_t cur_k = min_u32(out_K - (kt << arg->log2_kt), 1u << arg->log2_kt);
  const uint32_t local_row = row & ((1u << arg->log2_kt) - 1u);
  const uint32_t replicas = arg->QBLK >> __builtin_ctz(TILE_DMA_MXU_NT);
  for (uint32_t replica = 0; replica < replicas; ++replica) {
    const uint32_t n = col + replica * TILE_DMA_MXU_NT;
    if (row >= out_K || n >= out_N) continue;
    const uint32_t nt = n >> arg->log2_nt;
    const uint32_t nb = (n & ((1u << arg->log2_nt) - 1u)) >> __builtin_ctz(TILE_DMA_MXU_NT);
    const uint64_t offset = scale_slot_base(arg, kt, nt)
        + (uint64_t)(nb * cur_k + local_row) * TILE_ELEM_BYTES;
    store_u16(reinterpret_cast<uint8_t*>(arg->scale_addr), offset, fused_arith_to_bits(scale));
    store_u16(reinterpret_cast<uint8_t*>(arg->zero_addr), offset,
        arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC ? 0u : fused_zero_storage(zero));
  }
}

template <uint32_t Mode, bool FullTiles>
__attribute__((noinline))
static void quantize_row_pair_threads(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t K = arg->K, N = arg->N;
  const uint32_t qblk = arg->QBLK, log2_qblk = arg->log2_qblk;
  const uint32_t weight_K = padded_weight_K(K, N, 0u);
  const uint32_t weight_N = padded_weight_N(K, N, 0u);
  const uint32_t groups = (weight_N + qblk - 1u) >> log2_qblk;
  const uint32_t tasks = weight_K * groups;
  const uint32_t threads = gridDim.x * blockDim.x;
  const uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t lane = threadIdx.x % NUM_THREADS;
  const uint32_t parity = lane & 1u;
  auto src = reinterpret_cast<fp16_t*>(arg->src_addr);
  auto weight = reinterpret_cast<uint8_t*>(arg->weight_addr);
  const uint32_t source_N = arg->src_total_N == 0u ? N : arg->src_total_N;
  for (uint32_t task = tid; task < tasks; task += threads) {
    const uint32_t work = task >> 1;
    const uint32_t pair = work / groups;
    const uint32_t group = work - pair * groups;
    const uint32_t row = (pair << 1) + parity;
    const uint32_t start = group << log2_qblk;
    const uint32_t end = min_u32(start + qblk, weight_N);
    const cross_qparams_t params = compute_row_qparams(arg, row, start);
    store_row_qparams(arg, row, start, params.scale, params.zero);
    if (arg->logical_scale_addr != 0u && arg->logical_zero_addr != 0u && row < K && start < N) {
      const uint32_t index = row * ((N + qblk - 1u) >> log2_qblk) + group;
      reinterpret_cast<fp16_t*>(arg->logical_scale_addr)[index] = fused_arith_to_bits(params.scale);
      reinterpret_cast<fp16_t*>(arg->logical_zero_addr)[index] = fused_arith_to_bits(params.zero);
    }
    kv_fused_arith_t scale = params.scale;
    constexpr uint32_t mode = Mode;
    if (mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC)
      scale = fused_arith_from_bits(fused_arith_to_bits(scale));
    const uint64_t source_base = (uint64_t)(row + arg->src_row_offset) * source_N
        + arg->src_col_offset;
    const uint32_t row_pair = row & ~1u;
    const uint32_t kt_start = row_pair & ~((1u << arg->log2_kt) - 1u);
    const uint32_t cur_k = min_u32(weight_K - kt_start, 1u << arg->log2_kt);
    uint64_t offset = weight_offset_wtrans1(weight_K, weight_N, row_pair, start,
        arg->log2_kt, __builtin_ctz(TILE_DMA_MXU_KT), __builtin_ctz(TILE_DMA_MXU_NT));
    for (uint32_t n = start; n < end; ++n) {
      const uint32_t q = FullTiles || (row < K && n < N)
          ? quantize_loaded_value(src[source_base + n], scale, params.zero, mode) : 0u;
      uint32_t partner = vx_shfl_bfly(q, 1u, NUM_THREADS - 1u, 0);
      // The exchange needs both row lanes active. Keep it ahead of the
      // even-lane writer predicate instead of letting the compiler sink it.
      asm volatile("" : "+r"(partner) : : "memory");
      if (parity == 0u) weight[offset] = (uint8_t)((q & 0x0fu) | ((partner & 0x0fu) << 4));
      offset += TILE_DMA_MXU_KT >> 1;
      if ((n & (TILE_DMA_MXU_NT - 1u)) == TILE_DMA_MXU_NT - 1u)
        offset += (cur_k - TILE_DMA_MXU_KT) * (TILE_DMA_MXU_NT >> 1);
    }
  }
  store_prefill_qparams<true>(arg);
}

// Single-row quantization uses one warp, including all padded output writes.
__attribute__((noinline))
static void zero_single_group_outputs(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t lane = threadIdx.x;
  auto weight = reinterpret_cast<uint32_t*>(arg->weight_addr);
  const uint32_t weight_words = padded_weight_K(1u, arg->N, 0u)
      * (padded_weight_N(1u, arg->N, 0u) >> 1) / sizeof(uint32_t);
  for (uint32_t i = lane; i < weight_words; i += NUM_THREADS) weight[i] = 0;
  auto scales = reinterpret_cast<uint32_t*>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint32_t*>(arg->zero_addr);
  const uint32_t out_K = padded_qparam_K(1u, arg->N, arg->QBLK, 1u, 0u);
  const uint32_t out_N = padded_qparam_N(1u, arg->N, arg->QBLK, 1u, 0u);
  for (uint32_t nt = 0; nt < arg->n_dma_tiles; ++nt) {
    const uint32_t cur_n = min_u32(out_N - (nt << arg->log2_nt), 1u << arg->log2_nt);
    const uint32_t body = scale_slot_body_bytes(out_K, cur_n, arg->log2_qblk,
        __builtin_ctz(TILE_DMA_MXU_NT), arg->log2_ng_per_mxu_nt, 1u);
    const uint32_t words = align_up_u32(body, TILE_SCALE_SLOT_ALIGN) / sizeof(uint32_t);
    const uint64_t base = scale_slot_base(arg, 0u, nt) / sizeof(uint32_t);
    for (uint32_t i = lane; i < words; i += NUM_THREADS) {
      scales[base + i] = 0;
      zeros[base + i] = 0;
    }
  }
}

__attribute__((noinline))
static void quantize_single_group_row(kernel_arg_t *__UNIFORM__ arg) {
  const cross_qparams_t params = compute_cross_qparams<true, true>(arg, 0u, 0u);
  const uint32_t N = arg->N;
  const uint32_t mode = arg->quant_mode;
  kv_fused_arith_t scale = params.scale;
  if (mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC)
    scale = fused_arith_from_bits(fused_arith_to_bits(scale));
  const uint32_t source_N = arg->src_total_N == 0 ? N : arg->src_total_N;
  auto src = reinterpret_cast<fp16_t*>(arg->src_addr)
      + (uint64_t)arg->src_row_offset * source_N + arg->src_col_offset;
  auto weight = reinterpret_cast<uint8_t*>(arg->weight_addr);
  const uint32_t weight_K = padded_weight_K(1u, N, 0u);
  const uint32_t weight_N = padded_weight_N(1u, N, 0u);
  const uint32_t lane = threadIdx.x;
  for (uint32_t n = lane; n < N; n += NUM_THREADS) {
    const uint8_t value = quantize_loaded_value(src[n], scale, params.zero, mode);
    const uint64_t offset = weight_offset_wtrans1(weight_K, weight_N, 0u, n,
        arg->log2_kt, __builtin_ctz(TILE_DMA_MXU_KT), __builtin_ctz(TILE_DMA_MXU_NT));
    weight[offset] = value & 0x0fu;
  }
  store_cross_qparams(arg, 0u, 0u, params.scale, params.zero);
  if (lane == 0u) {
    if (arg->logical_scale_addr != 0 && arg->logical_zero_addr != 0) {
      *reinterpret_cast<fp16_t*>(arg->logical_scale_addr) = fused_arith_to_bits(params.scale);
      *reinterpret_cast<fp16_t*>(arg->logical_zero_addr) = fused_arith_to_bits(params.zero);
    }
  }
}

struct cross_pair_qparams_t {
  cross_qparams_t first;
  cross_qparams_t second;
};

__attribute__((noinline))
static cross_pair_qparams_t compute_column_pair_qparams(kernel_arg_t *__UNIFORM__ arg,
                                                       uint32_t k, uint32_t n) {
  cross_pair_qparams_t result = {};
  if (k >= arg->K || n >= arg->N) return result;
  const uint32_t lane = threadIdx.x % NUM_THREADS;
  const uint32_t source_N = arg->src_total_N == 0u ? arg->N : arg->src_total_N;
  auto src = reinterpret_cast<fp16_t*>(arg->src_addr)
      + (uint64_t)arg->src_row_offset * source_N + arg->src_col_offset + n;
  kv_fused_arith_t min0 = fused_arith_from_bits(src[(uint64_t)k * source_N]);
  kv_fused_arith_t max0 = min0;
  kv_fused_arith_t min1 = n + 1u < arg->N
      ? fused_arith_from_bits(src[(uint64_t)k * source_N + 1u]) : 0.0f;
  kv_fused_arith_t max1 = min1;
  const uint32_t end = min_u32(k + arg->QBLK, arg->K);
  if (end > k + 1u) {
    for (uint32_t row = k + lane; row < end; row += NUM_THREADS) {
      const kv_fused_arith_t v0 = fused_arith_from_bits(src[(uint64_t)row * source_N]);
      const kv_fused_arith_t v1 = n + 1u < arg->N
          ? fused_arith_from_bits(src[(uint64_t)row * source_N + 1u]) : 0.0f;
      if (v0 < min0) min0 = v0;
      if (v0 > max0) max0 = v0;
      if (v1 < min1) min1 = v1;
      if (v1 > max1) max1 = v1;
    }
    for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
      const kv_fused_arith_t other_min0 = shfl_down_float(min0, offset);
      const kv_fused_arith_t other_max0 = shfl_down_float(max0, offset);
      const kv_fused_arith_t other_min1 = shfl_down_float(min1, offset);
      const kv_fused_arith_t other_max1 = shfl_down_float(max1, offset);
      if (lane + offset < NUM_THREADS) {
        if (other_min0 < min0) min0 = other_min0;
        if (other_max0 > max0) max0 = other_max0;
        if (other_min1 < min1) min1 = other_min1;
        if (other_max1 > max1) max1 = other_max1;
      }
    }
    min0 = shfl_idx_float(min0, 0);
    max0 = shfl_idx_float(max0, 0);
    min1 = shfl_idx_float(min1, 0);
    max1 = shfl_idx_float(max1, 0);
  }
  make_warp_qparams(min0, max0,
      arg->quant_mode, &result.first.scale, &result.first.zero);
  if (n + 1u < arg->N)
    make_warp_qparams(min1, max1,
        arg->quant_mode, &result.second.scale, &result.second.zero);
  return result;
}

__attribute__((noinline))
static void zero_column_pair_padding(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t weight_K = padded_weight_K(arg->K, arg->N, 0u);
  if (weight_K == arg->K) return;
  const uint32_t weight_N = padded_weight_N(arg->K, arg->N, 0u);
  const uint32_t kt = (arg->K - 1u) >> arg->log2_kt;
  const uint32_t start = kt << arg->log2_kt;
  const uint32_t cur_k = weight_K - start;
  const uint32_t words_per_row = TILE_DMA_MXU_NT / 8u;
  const uint32_t words = cur_k * (weight_N >> 1) / sizeof(uint32_t);
  const uint64_t base = (uint64_t)start * (weight_N >> 1) / sizeof(uint32_t);
  auto output = reinterpret_cast<uint32_t*>(arg->weight_addr);
  const uint32_t threads = gridDim.x * blockDim.x;
  const uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  for (uint32_t i = tid; i < words; i += threads) {
    const uint32_t row = (i / words_per_row) % cur_k;
    if (start + row >= arg->K) output[base + i] = 0;
  }
}

__attribute__((noinline))
static void store_column_pair_qparams(kernel_arg_t *__UNIFORM__ arg,
    uint32_t k, uint32_t n, cross_pair_qparams_t params) {
  if (threadIdx.x % NUM_THREADS != 0u) return;
  const uint32_t out_K = padded_qparam_K(arg->K, arg->N, arg->QBLK, 0u, 0u);
  const uint32_t kt = k >> arg->log2_kt;
  const uint32_t nt = n >> arg->log2_nt;
  const uint32_t cur_k = min_u32(out_K - (kt << arg->log2_kt), 1u << arg->log2_kt);
  const uint32_t groups = (cur_k + arg->QBLK - 1u) >> arg->log2_qblk;
  const uint32_t nb = (n & ((1u << arg->log2_nt) - 1u)) >> __builtin_ctz(TILE_DMA_MXU_NT);
  const uint32_t group = (k & ((1u << arg->log2_kt) - 1u)) >> arg->log2_qblk;
  const uint32_t col = n & (TILE_DMA_MXU_NT - 1u);
  const uint64_t offset = scale_slot_base(arg, kt, nt)
      + (uint64_t)((nb * groups + group) * TILE_DMA_MXU_NT + col) * TILE_ELEM_BYTES;
  const uint32_t scales = fused_arith_to_bits(params.first.scale)
      | ((uint32_t)fused_arith_to_bits(params.second.scale) << 16);
  const uint32_t zeros = arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC ? 0u
      : fused_zero_storage(params.first.zero) | ((uint32_t)fused_zero_storage(params.second.zero) << 16);
  *reinterpret_cast<uint32_t*>(arg->scale_addr + offset) = scales;
  *reinterpret_cast<uint32_t*>(arg->zero_addr + offset) = zeros;
  if (arg->logical_scale_addr != 0u && arg->logical_zero_addr != 0u && k < arg->K && n < arg->N) {
    const uint32_t index = (k >> arg->log2_qblk) * arg->N + n;
    reinterpret_cast<fp16_t*>(arg->logical_scale_addr)[index] = fused_arith_to_bits(params.first.scale);
    reinterpret_cast<fp16_t*>(arg->logical_zero_addr)[index] = fused_arith_to_bits(params.first.zero);
    if (n + 1u < arg->N) {
      reinterpret_cast<fp16_t*>(arg->logical_scale_addr)[index + 1u] = fused_arith_to_bits(params.second.scale);
      reinterpret_cast<fp16_t*>(arg->logical_zero_addr)[index + 1u] = fused_arith_to_bits(params.second.zero);
    }
  }
}

template <uint32_t Mode>
__attribute__((noinline))
static void quantize_column_pair_warp(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t K = arg->K, N = arg->N;
  const uint32_t qblk = arg->QBLK;
  const uint32_t weight_K = padded_weight_K(K, N, 0u);
  const uint32_t weight_N = padded_weight_N(K, N, 0u);
  const uint32_t pairs = weight_N >> 1;
  const uint32_t tasks = ((K + qblk - 1u) >> arg->log2_qblk) * pairs;
  const uint32_t threads = gridDim.x * blockDim.x;
  const uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  const uint32_t lane = threadIdx.x % NUM_THREADS;
  const uint32_t source_N = arg->src_total_N == 0u ? N : arg->src_total_N;
  auto src = reinterpret_cast<fp16_t*>(arg->src_addr)
      + (uint64_t)arg->src_row_offset * source_N + arg->src_col_offset;
  auto output = reinterpret_cast<uint8_t*>(arg->weight_addr);
  for (uint32_t work = tid / NUM_THREADS; work < tasks; work += threads / NUM_THREADS) {
    const uint32_t group = work / pairs;
    const uint32_t n = (work - group * pairs) << 1;
    const uint32_t start = group << arg->log2_qblk;
    const uint32_t end = min_u32(start + qblk, K);
    const cross_pair_qparams_t params = compute_column_pair_qparams(arg, start, n);
    store_column_pair_qparams(arg, start, n, params);
    kv_fused_arith_t scale0 = params.first.scale, scale1 = params.second.scale;
    if (Mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
      scale0 = fused_arith_from_bits(fused_arith_to_bits(scale0));
      scale1 = fused_arith_from_bits(fused_arith_to_bits(scale1));
    }
    uint64_t offset = weight_offset_wtrans0(weight_K, weight_N, start + lane,
        n >> 1, arg->log2_kt, __builtin_ctz(TILE_DMA_MXU_KT), __builtin_ctz(TILE_DMA_MXU_NT));
    for (uint32_t row = start + lane; row < end; row += NUM_THREADS) {
      const uint8_t q0 = n < N ? quantize_loaded_value(src[(uint64_t)row * source_N + n],
          scale0, params.first.zero, Mode) : 0u;
      const uint8_t q1 = n + 1u < N ? quantize_loaded_value(src[(uint64_t)row * source_N + n + 1u],
          scale1, params.second.zero, Mode) : 0u;
      output[offset] = (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
      offset += NUM_THREADS * (TILE_DMA_MXU_NT >> 1);
    }
  }
  store_prefill_qparams<true>(arg);
}

template <bool AlongN, bool RowMajor>
__attribute__((noinline))
static void quantize_cross_group_pack(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto weight = reinterpret_cast<uint8_t *>(arg->weight_addr);
  auto scales = reinterpret_cast<uint8_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<uint8_t *>(arg->zero_addr);
  auto logical_scales = reinterpret_cast<fp16_t *>(arg->logical_scale_addr);
  auto logical_zeros = reinterpret_cast<fp16_t *>(arg->logical_zero_addr);

  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  constexpr uint32_t SOURCE_QDIR = AlongN ? 1u : 0u;
  const uint32_t GEMM_QDIR = arg->GEMM_QDIR;
  constexpr uint32_t WTRANS = AlongN ? 1u : 0u;
  const uint32_t src_layout = RowMajor ? SRC_LAYOUT_ROW_MAJOR : arg->src_layout;
  constexpr uint32_t SOURCE_TRANSPOSED = 0;
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
  constexpr uint32_t log2_mxu_kt = __builtin_ctz(TILE_DMA_MXU_KT);
  constexpr uint32_t log2_mxu_nt = __builtin_ctz(TILE_DMA_MXU_NT);
  const uint32_t log2_qblk = arg->log2_qblk;
  const uint32_t log2_ng_per_mxu_nt = arg->log2_ng_per_mxu_nt;
  const uint32_t kt_size = 1u << log2_kt;
  const uint32_t nt_size = 1u << log2_nt;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  const uint32_t weight_K = padded_weight_K(K, N, 0);
  const uint32_t weight_N = padded_weight_N(K, N, 0);
  const bool reuse_prefill_qparams =
#if KV_FUSED_PREFILL_QPARAM_REUSE
      ((SOURCE_QDIR == 1
        && ((SOURCE_TRANSPOSED != 0 && WTRANS != 0 && GEMM_QDIR == 0)
            || (SOURCE_TRANSPOSED == 0 && GEMM_QDIR == 1)))
       || (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && SOURCE_QDIR == 0
           && GEMM_QDIR == 0 && QBLK <= (1u << log2_kt)))
#if KV_FUSED_FP32_PARAMS
      // A source group wider than a DMA K tile needs qparams in each tile.
      // Let the generic qparam stage populate those slots independently.
      && (SOURCE_TRANSPOSED == 0 || QBLK <= (1u << log2_kt))
#endif
      ;
#else
      false;
#endif
    constexpr bool along_n = AlongN;
    const uint32_t axis_size = along_n ? weight_N : weight_K;
    const uint32_t pairs = (along_n ? weight_K : weight_N) >> 1;
    const uint32_t groups = (axis_size + QBLK - 1u) >> log2_qblk;
    const uint32_t warp = thread_id / NUM_THREADS;
    const uint32_t warps = total_threads / NUM_THREADS;
    const uint32_t lane = threadIdx.x % NUM_THREADS;
    for (uint32_t work = warp; work < pairs * groups; work += warps) {
      const uint32_t pair = work / groups;
      const uint32_t group = work - pair * groups;
      const uint32_t axis_start = group << log2_qblk;
      const uint32_t axis_end = min_u32(axis_start + QBLK, axis_size);
      const uint32_t k0 = along_n ? pair << 1 : axis_start;
      const uint32_t n0 = along_n ? axis_start : pair << 1;
      cross_qparams_t params0, params1;
      if (!AlongN && RowMajor) {
        const cross_pair_qparams_t pair_params = compute_column_pair_qparams(arg, k0, n0);
        params0 = pair_params.first;
        params1 = pair_params.second;
      } else {
        params0 = compute_cross_qparams<AlongN, RowMajor>(arg, k0, n0);
        params1 = compute_cross_qparams<AlongN, RowMajor>(arg,
            k0 + (along_n ? 1u : 0u), n0 + (along_n ? 0u : 1u));
      }
      kv_fused_arith_t scale0 = params0.scale, zero0 = params0.zero;
      kv_fused_arith_t scale1 = params1.scale, zero1 = params1.zero;
      if (reuse_prefill_qparams) {
        store_cross_qparams(arg, k0, n0, scale0, zero0);
        store_cross_qparams(arg, k0 + (along_n ? 1u : 0u),
            n0 + (along_n ? 0u : 1u), scale1, zero1);
        if (lane == 0u && logical_scales != nullptr && logical_zeros != nullptr) {
          const uint32_t logical_groups = along_n
              ? (N + QBLK - 1u) >> log2_qblk : N;
          for (uint32_t part = 0; part < 2u; ++part) {
            const uint32_t row = k0 + (along_n ? part : 0u);
            const uint32_t col = n0 + (along_n ? 0u : part);
            if (row < K && col < N) {
              const uint32_t index = along_n
                  ? row * logical_groups + group : group * N + col;
              logical_scales[index] = fused_arith_to_bits(part ? scale1 : scale0);
              logical_zeros[index] = fused_arith_to_bits(part ? zero1 : zero0);
            }
          }
        }
      }
      if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
        scale0 = fused_arith_from_bits(fused_arith_to_bits(scale0));
        scale1 = fused_arith_from_bits(fused_arith_to_bits(scale1));
      }
      const uint32_t first_k = along_n ? k0 : axis_start + lane;
      const uint32_t first_n = along_n ? axis_start + lane : n0;
      uint64_t source_offset = (uint64_t)(first_k + source_view.row_offset)
          * source_view.total_n + first_n + source_view.col_offset;
      const uint64_t source_step = along_n ? NUM_THREADS : (uint64_t)NUM_THREADS * source_view.total_n;
      const uint64_t second_offset = along_n ? source_view.total_n : 1u;
      uint64_t weight_offset = along_n
          ? weight_offset_wtrans1(weight_K, weight_N, first_k, first_n,
              log2_kt, log2_mxu_kt, log2_mxu_nt)
          : weight_offset_wtrans0(weight_K, weight_N, first_k, first_n >> 1,
              log2_kt, log2_mxu_kt, log2_mxu_nt);
      const uint32_t cur_k = min_u32(weight_K - (k0 & ~((1u << log2_kt) - 1u)), 1u << log2_kt);
      const uint32_t weight_step = along_n
          ? cur_k * (NUM_THREADS >> 1) : NUM_THREADS * (TILE_DMA_MXU_NT >> 1);
      for (uint32_t axis = axis_start + lane; axis < axis_end; axis += NUM_THREADS) {
        if (RowMajor) {
          const bool valid0 = along_n ? k0 < K && axis < N : axis < K && n0 < N;
          const bool valid1 = along_n ? k0 + 1u < K && axis < N : axis < K && n0 + 1u < N;
          const uint8_t q0 = valid0 ? quantize_loaded_value(src[source_offset], scale0, zero0, quant_mode) : 0u;
          const uint8_t q1 = valid1 ? quantize_loaded_value(src[source_offset + second_offset], scale1, zero1, quant_mode) : 0u;
          weight[weight_offset] = (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
          source_offset += source_step;
          weight_offset += weight_step;
        } else {
        const uint32_t k = along_n ? k0 : axis;
        const uint32_t n = along_n ? axis : n0;
        const uint8_t q0 = quant_with_params(src, K, N, k, n, src_layout,
            log2_mt, log2_mxu_nt, scale0, zero0, quant_mode, source_view);
        const uint8_t q1 = quant_with_params(src, K, N,
            k + (along_n ? 1u : 0u), n + (along_n ? 0u : 1u), src_layout,
            log2_mt, log2_mxu_nt, scale1, zero1, quant_mode, source_view);
        const uint64_t offset = along_n
            ? weight_offset_wtrans1(weight_K, weight_N, k, n,
                log2_kt, log2_mxu_kt, log2_mxu_nt)
            : weight_offset_wtrans0(weight_K, weight_N, k, n >> 1,
                log2_kt, log2_mxu_kt, log2_mxu_nt);
        weight[offset] = (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
        }
      }
    }

  if (reuse_prefill_qparams) store_prefill_qparams<true>(arg);
  else store_prefill_qparams<false>(arg);
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

  if (arg->persistent_mode != 0) {
    const uint32_t cache_K = arg->cache_capacity;
    const uint32_t cache_N = N;
    const uint32_t position = arg->cache_position;
    const uint32_t weight_K = padded_weight_K(
        cache_K, cache_N, SOURCE_TRANSPOSED);
    const uint32_t weight_N = padded_weight_N(
        cache_K, cache_N, SOURCE_TRANSPOSED);
    kv_fused_arith_t scale = 1.0f;
    kv_fused_arith_t zero = 0.0f;
#if KV_FUSED_PERSISTENT_WARP
    const bool contiguous_single_row =
        K == 1u && source_view.total_k == 1u
        && source_view.row_offset == 0u;
    const fp16_t* persistent_src = contiguous_single_row
        ? src + source_view.col_offset
        : src;
    const source_view_t persistent_view = contiguous_single_row
        ? source_view_t{1u, N, 0u, 0u}
        : source_view;
    compute_params_warp(
        persistent_src, K, N, QBLK, SOURCE_QDIR, 0, 0,
        contiguous_single_row ? SRC_LAYOUT_ROW_MAJOR : src_layout,
        log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
        persistent_view, threadIdx.x, &scale, &zero);
#else
    compute_params(src, K, N, QBLK, SOURCE_QDIR, 0, 0, src_layout,
                   log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                   source_view, &scale, &zero);
#endif
    const kv_fused_arith_t stored_scale = fused_arith_from_bits(fused_arith_to_bits(scale));
    const kv_fused_arith_t quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
        ? stored_scale : scale;

    for (uint32_t pair = thread_id; pair < (N >> 1); pair += total_threads) {
      const uint32_t d0 = pair << 1;
      const bool contiguous_single_row =
          K == 1u && source_view.total_k == 1u
          && source_view.row_offset == 0u;
      const uint8_t q0 = contiguous_single_row
          ? quantize_loaded_value(
                src[source_view.col_offset + d0],
                quant_scale, zero, quant_mode)
          : quant_with_params(
                src, K, N, 0, d0, src_layout, log2_mt, log2_mxu_nt,
                quant_scale, zero, quant_mode, source_view);
      const uint8_t q1 = contiguous_single_row
          ? quantize_loaded_value(
                src[source_view.col_offset + d0 + 1u],
                quant_scale, zero, quant_mode)
          : quant_with_params(
                src, K, N, 0, d0 + 1, src_layout, log2_mt, log2_mxu_nt,
                quant_scale, zero, quant_mode, source_view);
      const uint8_t packed = (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      if (SOURCE_TRANSPOSED != 0) {
        weight[weight_offset_wtrans1(weight_K, weight_N, d0, position,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] = packed;
      } else {
        weight[weight_offset_wtrans0(weight_K, weight_N, position, pair,
                                     log2_kt, log2_mxu_kt, log2_mxu_nt)] = packed;
      }
    }

    const uint32_t out_K = padded_qparam_K(
        cache_K, cache_N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
    const uint32_t out_N = padded_qparam_N(
        cache_K, cache_N, QBLK, GEMM_QDIR, SOURCE_TRANSPOSED);
    if (GEMM_QDIR == 0) {
      if (thread_id == 0) {
        const uint32_t nt_dma = position >> log2_nt;
        const uint32_t elem = position & ((1u << log2_nt) - 1u);
        const uint64_t dst_off = scale_slot_base(arg, 0, nt_dma)
                               + (uint64_t)elem * TILE_ELEM_BYTES;
        store_u16(scales, dst_off, fused_arith_to_bits(scale));
        store_u16(zeros, dst_off,
                  quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
                      ? 0u : fused_zero_storage(zero));
      }
    } else {
      const uint32_t kt = position >> log2_kt;
      const uint32_t kt_start = kt << log2_kt;
      const uint32_t cur_k = min_u32(out_K - kt_start, 1u << log2_kt);
      const uint32_t k_local = position - kt_start;
      const uint32_t n_blocks = out_N >> log2_mxu_nt;
      for (uint32_t nb = thread_id; nb < n_blocks; nb += total_threads) {
        const uint32_t elem = nb * cur_k + k_local;
        const uint64_t dst_off = scale_slot_base(arg, kt, 0)
                               + (uint64_t)elem * TILE_ELEM_BYTES;
        store_u16(scales, dst_off, fused_arith_to_bits(scale));
        store_u16(zeros, dst_off,
                  quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
                      ? 0u : fused_zero_storage(zero));
      }
    }
    if (thread_id == 0
        && arg->logical_scale_addr != 0
        && arg->logical_zero_addr != 0) {
      logical_scales[position] = fused_arith_to_bits(scale);
      logical_zeros[position] = fused_arith_to_bits(zero);
    }
    return;
  }

  const uint32_t weight_K = padded_weight_K(K, N, SOURCE_TRANSPOSED);
  const uint32_t weight_N = padded_weight_N(K, N, SOURCE_TRANSPOSED);
  const uint32_t weight_bytes = weight_K * (weight_N >> 1);
  const uint32_t prefill_work_start = KV_FUSED_PREFILL_WARP_GROUP
      ? thread_id / NUM_THREADS : thread_id;
  const uint32_t prefill_work_stride = KV_FUSED_PREFILL_WARP_GROUP
      ? total_threads / NUM_THREADS : total_threads;
  const uint32_t prefill_lane = threadIdx.x & (NUM_THREADS - 1u);
  const bool reuse_prefill_qparams =
#if KV_FUSED_PREFILL_QPARAM_REUSE
      SOURCE_QDIR == 1
      && ((SOURCE_TRANSPOSED != 0 && WTRANS != 0 && GEMM_QDIR == 0)
          || (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && GEMM_QDIR == 1))
#if KV_FUSED_FP32_PARAMS
      // A source group wider than a DMA K tile needs qparams in each tile.
      // Let the generic qparam stage populate those slots independently.
      && (SOURCE_TRANSPOSED == 0 || QBLK <= (1u << log2_kt))
#endif
      ;
#else
      false;
#endif
  if (SOURCE_TRANSPOSED != 0 && WTRANS != 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t logical_K = weight_K;
    const uint32_t logical_N = weight_N;
    const uint32_t source_groups = (logical_K + QBLK - 1u) >> log2_qblk;
    const uint32_t source_group_work = logical_N * source_groups;
    for (uint32_t work = prefill_work_start; work < source_group_work;
         work += prefill_work_stride) {
#if KV_FUSED_SOURCE_GROUP1_FAST
      const uint32_t source_row =
          source_groups == 1u ? work : work / source_groups;
      const uint32_t group =
          source_groups == 1u ? 0u : work - source_row * source_groups;
#else
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
#endif
      const uint32_t source_col_start = group << log2_qblk;
      const uint32_t source_col_end = min_u32(source_col_start + QBLK, logical_K);
      kv_fused_arith_t scale = 1.0f;
      kv_fused_arith_t zero = 0.0f;
#if KV_FUSED_PREFILL_WARP_GROUP
      compute_params_warp(
          src, K, N, QBLK, SOURCE_QDIR, source_row, source_col_start,
          src_layout, log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
          source_view, prefill_lane, &scale, &zero);
#elif KV_FUSED_SOURCE_CURSOR
      compute_params_qdir1_cursor(
          src, K, N, QBLK, source_row, source_col_start, src_layout,
          log2_qblk, log2_mt, log2_mxu_nt, quant_mode, source_view,
          &scale, &zero);
#else
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout,
                     log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
#endif
      if (reuse_prefill_qparams
          && (!KV_FUSED_PREFILL_WARP_GROUP || prefill_lane == 0u)) {
        store_reused_tiled_qparam(
            arg, scales, zeros, K, N, QBLK, GEMM_QDIR,
            SOURCE_TRANSPOSED, quant_mode, source_row, source_col_start,
            scale, zero);
        if (arg->logical_scale_addr != 0
            && arg->logical_zero_addr != 0
            && source_row < K
            && source_col_start < N) {
          const uint32_t logical_groups =
              (N + QBLK - 1u) >> log2_qblk;
          const uint32_t logical_index =
              source_row * logical_groups + group;
          logical_scales[logical_index] = fused_arith_to_bits(scale);
          logical_zeros[logical_index] = fused_arith_to_bits(zero);
        }
      }
      const kv_fused_arith_t stored_scale = fused_arith_from_bits(fused_arith_to_bits(scale));
      const kv_fused_arith_t quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? stored_scale : scale;
#if KV_FUSED_SOURCE_CURSOR
      source_row_cursor_t source_cursor = make_source_row_cursor(
          src, K, N, source_row, source_col_start, src_layout,
          log2_mt, log2_mxu_nt, source_view);
#endif
#if KV_FUSED_PREFILL_TILED_CHUNK
      const uint32_t source_tile_size = 1u << log2_mxu_nt;
      if (source_tile_size >= 4u && source_cursor.valid_row && source_col_end <= N
          && source_cursor.within_tile == 0u
          && source_cursor.tile_mask == source_tile_size - 1u
          && source_tile_size == (1u << log2_mxu_kt)
          && ((source_col_end - source_col_start) & (source_tile_size - 1u)) == 0u) {
        const fp16_t* tile = src + source_cursor.offset;
        for (uint32_t col = source_col_start; col < source_col_end;
             col += source_tile_size) {
          uint8_t* packed = weight + weight_offset_wtrans1(logical_K, logical_N, col, source_row, log2_kt, log2_mxu_kt, log2_mxu_nt);
          auto packed_words = reinterpret_cast<uint16_t*>(packed);
          for (uint32_t pair = 0; pair < source_tile_size / 2u; pair += 2u) {
            const uint8_t q0 = quantize_loaded_value(
                tile[2u * pair], quant_scale, zero, quant_mode);
            const uint8_t q1 = quantize_loaded_value(
                tile[2u * pair + 1u], quant_scale, zero, quant_mode);
            const uint8_t q2 = quantize_loaded_value(
                tile[2u * pair + 2u], quant_scale, zero, quant_mode);
            const uint8_t q3 = quantize_loaded_value(
                tile[2u * pair + 3u], quant_scale, zero, quant_mode);
            packed_words[pair / 2u] = (uint16_t)((q0 & 0x0f)
                | ((q1 & 0x0f) << 4) | ((q2 & 0x0f) << 8) | ((q3 & 0x0f) << 12));
          }
          tile += source_cursor.tile_advance + source_tile_size;
        }
        continue;
      }
#endif
#if KV_FUSED_WEIGHT_CURSOR_WTRANS1
      weight_wtrans1_cursor_t weight_cursor = make_weight_wtrans1_cursor(
          logical_K, logical_N, source_col_start, source_row,
          log2_kt, log2_mxu_kt, log2_mxu_nt);
#endif
      for (uint32_t source_col = source_col_start
               + (KV_FUSED_PREFILL_WARP_GROUP ? 2u * prefill_lane : 0u);
           source_col < source_col_end;
           source_col += KV_FUSED_PREFILL_WARP_GROUP ? 2u * NUM_THREADS : 2u) {
#if KV_FUSED_SOURCE_CURSOR
        bool valid0 = false;
        bool valid1 = false;
        const fp16_t value0 =
            source_row_cursor_next(&source_cursor, &valid0);
        const fp16_t value1 =
            source_row_cursor_next(&source_cursor, &valid1);
        const uint8_t q0 = valid0
            ? quantize_loaded_value(
                  value0, quant_scale, zero, quant_mode)
            : 0;
        const uint8_t q1 = valid1
            ? quantize_loaded_value(
                  value1, quant_scale, zero, quant_mode)
            : 0;
#else
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
#endif
#if KV_FUSED_WEIGHT_CURSOR_WTRANS1
        const uint64_t weight_offset =
            weight_wtrans1_cursor_next(&weight_cursor);
#else
        const uint64_t weight_offset = weight_offset_wtrans1(
            logical_K, logical_N, source_col, source_row,
            log2_kt, log2_mxu_kt, log2_mxu_nt);
#endif
        weight[weight_offset] =
            (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
      }
    }
  } else if (SOURCE_TRANSPOSED == 0 && WTRANS == 0 && SOURCE_QDIR == 1 && QBLK >= 2) {
    const uint32_t source_groups = (weight_N + QBLK - 1u) >> log2_qblk;
    const uint32_t source_group_work = weight_K * source_groups;
    for (uint32_t work = prefill_work_start; work < source_group_work;
         work += prefill_work_stride) {
#if KV_FUSED_SOURCE_GROUP1_FAST
      const uint32_t source_row =
          source_groups == 1u ? work : work / source_groups;
      const uint32_t group =
          source_groups == 1u ? 0u : work - source_row * source_groups;
#else
      const uint32_t source_row = work / source_groups;
      const uint32_t group = work - source_row * source_groups;
#endif
      const uint32_t source_col_start = group << log2_qblk;
      const uint32_t source_col_end = min_u32(source_col_start + QBLK, weight_N);
      kv_fused_arith_t scale = 1.0f;
      kv_fused_arith_t zero = 0.0f;
#if KV_FUSED_PREFILL_WARP_GROUP
      compute_params_warp(
          src, K, N, QBLK, SOURCE_QDIR, source_row, source_col_start,
          src_layout, log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
          source_view, prefill_lane, &scale, &zero);
#elif KV_FUSED_SOURCE_CURSOR
      compute_params_qdir1_cursor(
          src, K, N, QBLK, source_row, source_col_start, src_layout,
          log2_qblk, log2_mt, log2_mxu_nt, quant_mode, source_view,
          &scale, &zero);
#else
      compute_params(src, K, N, QBLK, SOURCE_QDIR,
                     source_row, source_col_start, src_layout,
                     log2_qblk, log2_mt, log2_mxu_nt, quant_mode,
                     source_view, &scale, &zero);
#endif
      if (reuse_prefill_qparams
          && (!KV_FUSED_PREFILL_WARP_GROUP || prefill_lane == 0u)) {
        store_reused_tiled_qparam(
            arg, scales, zeros, K, N, QBLK, GEMM_QDIR,
            SOURCE_TRANSPOSED, quant_mode, source_row, source_col_start,
            scale, zero);
        if (arg->logical_scale_addr != 0
            && arg->logical_zero_addr != 0
            && source_row < K
            && source_col_start < N) {
          const uint32_t logical_groups =
              (N + QBLK - 1u) >> log2_qblk;
          const uint32_t logical_index =
              source_row * logical_groups + group;
          logical_scales[logical_index] = fused_arith_to_bits(scale);
          logical_zeros[logical_index] = fused_arith_to_bits(zero);
        }
      }
      const kv_fused_arith_t stored_scale = fused_arith_from_bits(fused_arith_to_bits(scale));
      const kv_fused_arith_t quant_scale = quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? stored_scale : scale;
#if KV_FUSED_SOURCE_CURSOR
      source_row_cursor_t source_cursor = make_source_row_cursor(
          src, K, N, source_row, source_col_start, src_layout,
          log2_mt, log2_mxu_nt, source_view);
#endif
#if KV_FUSED_PREFILL_TILED_CHUNK
      const uint32_t source_tile_size = 1u << log2_mxu_nt;
      if (source_tile_size >= 4u && source_cursor.valid_row && source_col_end <= N
          && source_cursor.within_tile == 0u
          && source_cursor.tile_mask == source_tile_size - 1u
          && source_tile_size == (1u << log2_mxu_nt)
          && ((source_col_end - source_col_start) & (source_tile_size - 1u)) == 0u) {
        const fp16_t* tile = src + source_cursor.offset;
        for (uint32_t col = source_col_start; col < source_col_end;
             col += source_tile_size) {
          uint8_t* packed = weight + weight_offset_wtrans0(weight_K, weight_N, source_row, col >> 1, log2_kt, log2_mxu_kt, log2_mxu_nt);
          auto packed_words = reinterpret_cast<uint16_t*>(packed);
          for (uint32_t pair = 0; pair < source_tile_size / 2u; pair += 2u) {
            const uint8_t q0 = quantize_loaded_value(
                tile[2u * pair], quant_scale, zero, quant_mode);
            const uint8_t q1 = quantize_loaded_value(
                tile[2u * pair + 1u], quant_scale, zero, quant_mode);
            const uint8_t q2 = quantize_loaded_value(
                tile[2u * pair + 2u], quant_scale, zero, quant_mode);
            const uint8_t q3 = quantize_loaded_value(
                tile[2u * pair + 3u], quant_scale, zero, quant_mode);
            packed_words[pair / 2u] = (uint16_t)((q0 & 0x0f)
                | ((q1 & 0x0f) << 4) | ((q2 & 0x0f) << 8) | ((q3 & 0x0f) << 12));
          }
          tile += source_cursor.tile_advance + source_tile_size;
        }
        continue;
      }
#endif
#if KV_FUSED_WEIGHT_CURSOR_WTRANS0
      weight_wtrans0_cursor_t weight_cursor = make_weight_wtrans0_cursor(
          weight_K, weight_N, source_row, source_col_start >> 1,
          log2_kt, log2_mxu_kt, log2_mxu_nt);
#endif
      for (uint32_t source_col = source_col_start
               + (KV_FUSED_PREFILL_WARP_GROUP ? 2u * prefill_lane : 0u);
           source_col < source_col_end;
           source_col += KV_FUSED_PREFILL_WARP_GROUP ? 2u * NUM_THREADS : 2u) {
#if KV_FUSED_SOURCE_CURSOR
        bool valid0 = false;
        bool valid1 = false;
        const fp16_t value0 =
            source_row_cursor_next(&source_cursor, &valid0);
        const fp16_t value1 =
            source_row_cursor_next(&source_cursor, &valid1);
        const uint8_t q0 = valid0
            ? quantize_loaded_value(
                  value0, quant_scale, zero, quant_mode)
            : 0;
        const uint8_t q1 = valid1
            ? quantize_loaded_value(
                  value1, quant_scale, zero, quant_mode)
            : 0;
#else
        const uint8_t q0 = quant_with_params(src, K, N, source_row, source_col,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
        const uint8_t q1 = quant_with_params(src, K, N, source_row, source_col + 1,
                                             src_layout, log2_mt, log2_mxu_nt,
                                             quant_scale, zero, quant_mode,
                                             source_view);
#endif
#if KV_FUSED_WEIGHT_CURSOR_WTRANS0
        const uint64_t weight_offset =
            weight_wtrans0_cursor_next(&weight_cursor);
#else
        const uint64_t weight_offset = weight_offset_wtrans0(
            weight_K, weight_N, source_row, source_col >> 1,
            log2_kt, log2_mxu_kt, log2_mxu_nt);
#endif
        weight[weight_offset] =
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

  if (reuse_prefill_qparams) store_prefill_qparams<true>(arg);
  else store_prefill_qparams<false>(arg);
}

#if KV_FUSED_SPLIT_PERSISTENT
__attribute__((noinline))
fp16_t persistent_float_to_fp16(kv_fused_arith_t value) {
  return fused_arith_to_bits(value);
}

__attribute__((noinline))
void persistent_store_qparams(kernel_arg_t *__UNIFORM__ arg,
                              kv_fused_arith_t scale,
                              kv_fused_arith_t zero,
                              uint32_t lane) {
  if (lane == 0) {
    auto scales = reinterpret_cast<uint8_t *>(arg->scale_addr);
    auto zeros = reinterpret_cast<uint8_t *>(arg->zero_addr);
    auto logical_scales =
        reinterpret_cast<fp16_t *>(arg->logical_scale_addr);
    auto logical_zeros =
        reinterpret_cast<fp16_t *>(arg->logical_zero_addr);
    const uint32_t position = arg->cache_position;
    const uint16_t scale_bits = persistent_float_to_fp16(scale);
    const uint16_t tiled_zero_bits =
        arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
            ? 0u : fused_zero_storage(zero);

    if (arg->GEMM_QDIR == 0) {
      const uint32_t nt_dma = position >> arg->log2_nt;
      const uint32_t elem =
          position & ((1u << arg->log2_nt) - 1u);
      const uint64_t dst_off =
          scale_slot_base(arg, 0, nt_dma)
          + (uint64_t)elem * TILE_ELEM_BYTES;
      store_u16(scales, dst_off, scale_bits);
      store_u16(zeros, dst_off, tiled_zero_bits);
    } else {
      const uint32_t out_K = padded_qparam_K(
          arg->cache_capacity, arg->N, arg->QBLK, arg->GEMM_QDIR,
          arg->SOURCE_TRANSPOSED);
      const uint32_t out_N = padded_qparam_N(
          arg->cache_capacity, arg->N, arg->QBLK, arg->GEMM_QDIR,
          arg->SOURCE_TRANSPOSED);
      const uint32_t kt = position >> arg->log2_kt;
      const uint32_t kt_start = kt << arg->log2_kt;
      const uint32_t cur_k =
          min_u32(out_K - kt_start, 1u << arg->log2_kt);
      const uint32_t k_local = position - kt_start;
      const uint32_t n_blocks = out_N >> arg->log2_mxu_nt;
      const uint64_t slot_base = scale_slot_base(arg, kt, 0);
      for (uint32_t nb = 0; nb < n_blocks; ++nb) {
        const uint64_t dst_off =
            slot_base
            + (uint64_t)(nb * cur_k + k_local) * TILE_ELEM_BYTES;
        store_u16(scales, dst_off, scale_bits);
        store_u16(zeros, dst_off, tiled_zero_bits);
      }
    }

    if (arg->logical_scale_addr != 0
        && arg->logical_zero_addr != 0) {
      logical_scales[position] = scale_bits;
      logical_zeros[position] = persistent_float_to_fp16(zero);
    }
  }
}

// Append updates are a single contiguous source row launched as one warp.
// Keep this hot path out of the much larger full-cache/prefill function so its
// register frame and instruction footprint contain only append-update work.
__attribute__((noinline))
void kernel_kv_cache_quant_layout_fused_persistent(
    kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto weight = reinterpret_cast<uint8_t *>(arg->weight_addr);

  const uint32_t N = arg->N;
  const uint32_t quant_mode = arg->quant_mode;
  const uint32_t lane = threadIdx.x;
  const fp16_t* token = src + arg->src_col_offset;

  kv_fused_arith_t min_v = fused_arith_from_bits(token[0]);
  kv_fused_arith_t max_v = min_v;
  for (uint32_t n = lane; n < N; n += NUM_THREADS) {
    const kv_fused_arith_t value = fused_arith_from_bits(token[n]);
    if (value < min_v) min_v = value;
    if (value > max_v) max_v = value;
  }
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const kv_fused_arith_t other_min = shfl_down_float(min_v, offset);
    const kv_fused_arith_t other_max = shfl_down_float(max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < min_v) min_v = other_min;
      if (other_max > max_v) max_v = other_max;
    }
  }
  min_v = shfl_idx_float(min_v, 0);
  max_v = shfl_idx_float(max_v, 0);

  kv_fused_arith_t scale;
  kv_fused_arith_t zero;
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const kv_fused_arith_t abs_min = min_v < 0.0f ? -min_v : min_v;
    const kv_fused_arith_t abs_max = max_v < 0.0f ? -max_v : max_v;
    kv_fused_arith_t absmax = abs_min > abs_max ? abs_min : abs_max;
    if (absmax < 1e-8f) absmax = 1e-8f;
    scale = absmax / 7.5f;
    zero = 0.0f;
  } else {
    const kv_fused_arith_t range = max_v - min_v;
    scale =
        quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
    if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
        || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
            && range / 15.0f > 1e-8f)) {
      scale = range / 15.0f;
    }
    if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
      zero = (kv_fused_arith_t)round_half_even(spinquant_ratio(-min_v, scale)) - 8.0f;
    } else {
      int32_t zp = legacy_zero(min_v, range, scale);
      if (zp < 0) zp = 0;
      if (zp > 15) zp = 15;
      zero = (kv_fused_arith_t)zp;
    }
  }

  kv_fused_arith_t quant_scale = scale;
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    quant_scale = fused_arith_from_bits(fused_arith_to_bits(scale));
  }
  const uint32_t cache_K = arg->cache_capacity;
  const uint32_t position = arg->cache_position;
  const uint32_t source_transposed = arg->SOURCE_TRANSPOSED;
  const uint32_t weight_K =
      padded_weight_K(cache_K, N, source_transposed);
  const uint32_t weight_N =
      padded_weight_N(cache_K, N, source_transposed);

  persistent_store_qparams(arg, scale, zero, lane);

  for (uint32_t pair = lane; pair < (N >> 1); pair += NUM_THREADS) {
    const uint32_t d0 = pair << 1;
    const uint8_t q0 =
        quantize_loaded_value(token[d0], quant_scale, zero, quant_mode);
    const uint8_t q1 =
        quantize_loaded_value(token[d0 + 1u], quant_scale, zero, quant_mode);
    const uint8_t packed =
        (uint8_t)((q0 & 0x0f) | ((q1 & 0x0f) << 4));
    if (source_transposed != 0) {
      weight[weight_offset_wtrans1(
          weight_K, weight_N, d0, position,
          arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt)] = packed;
    } else {
      weight[weight_offset_wtrans0(
          weight_K, weight_N, position, pair,
          arg->log2_kt, arg->log2_mxu_kt, arg->log2_mxu_nt)] = packed;
    }
  }
}
#endif

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_KV_CACHE_QUANT_LAYOUT_FUSED_W4A16:
#if KV_FUSED_SPLIT_PERSISTENT
      if (arg->persistent_mode != 0
          && arg->K == 1u
          && arg->src_total_K == 1u
          && arg->QDIR == 1u
          && arg->QBLK >= arg->N) {
        kernel_kv_cache_quant_layout_fused_persistent(arg);
      } else {
        if (KV_FUSED_PREFILL_QPARAM_REUSE && arg->persistent_mode == 0
            && arg->SOURCE_TRANSPOSED == 0 && arg->QBLK >= 2u
            && ((arg->QDIR == 1u && arg->WTRANS != 0)
                || (arg->QDIR == 0u && arg->WTRANS == 0))) {
          if (arg->grid_dim[0] == 1u && arg->block_dim[0] == NUM_THREADS
              && kv_fused_single_group_shape(arg->K, arg->N, arg->QBLK,
                  arg->QDIR, arg->WTRANS, arg->GEMM_QDIR,
                  arg->SOURCE_TRANSPOSED, arg->src_layout)) {
            zero_single_group_outputs(arg);
            quantize_single_group_row(arg);
          } else if (arg->QDIR == 1u && arg->GEMM_QDIR == 1u
                     && arg->QBLK >= TILE_DMA_MXU_NT && NUM_THREADS >= 2
                     && arg->src_layout == SRC_LAYOUT_ROW_MAJOR) {
            const bool full_tiles = arg->K == padded_weight_K(arg->K, arg->N, 0u)
                && arg->N == padded_weight_N(arg->K, arg->N, 0u);
            if (arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
              if (full_tiles) quantize_row_pair_threads<KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC, true>(arg);
              else quantize_row_pair_threads<KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC, false>(arg);
            } else if (arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
              if (full_tiles) quantize_row_pair_threads<KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC, true>(arg);
              else quantize_row_pair_threads<KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC, false>(arg);
            } else {
              if (full_tiles) quantize_row_pair_threads<KV_QUANT_LEGACY_UINT4_ASYMMETRIC, true>(arg);
              else quantize_row_pair_threads<KV_QUANT_LEGACY_UINT4_ASYMMETRIC, false>(arg);
            }
          } else if (arg->QDIR == 1u) {
            if (arg->src_layout == SRC_LAYOUT_ROW_MAJOR)
              quantize_cross_group_pack<true, true>(arg);
            else quantize_cross_group_pack<true, false>(arg);
          } else if (arg->src_layout == SRC_LAYOUT_ROW_MAJOR && arg->GEMM_QDIR == 0u
                     && arg->QBLK <= (1u << arg->log2_kt) && TILE_DMA_MXU_NT >= 8u) {
            zero_column_pair_padding(arg);
            if (arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC)
              quantize_column_pair_warp<KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC>(arg);
            else if (arg->quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC)
              quantize_column_pair_warp<KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC>(arg);
            else quantize_column_pair_warp<KV_QUANT_LEGACY_UINT4_ASYMMETRIC>(arg);
          } else {
            if (arg->src_layout == SRC_LAYOUT_ROW_MAJOR && arg->QBLK <= (1u << arg->log2_kt))
              quantize_cross_group_pack<false, true>(arg);
            else quantize_cross_group_pack<false, false>(arg);
          }
        } else {
          kernel_kv_cache_quant_layout_fused(arg);
        }
      }
#else
      kernel_kv_cache_quant_layout_fused(arg);
#endif
      break;
    default:
      break;
  }
}

KV_FUSED_SMALL_HELPER uint32_t effective_power_kernel_iterations(
    const kernel_arg_t* arg) {
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
