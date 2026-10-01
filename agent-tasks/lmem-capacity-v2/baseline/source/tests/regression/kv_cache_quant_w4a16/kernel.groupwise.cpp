#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

#define KV_QUANT_INLINE static inline __attribute__((always_inline))

KV_QUANT_INLINE uint32_t min_u32(uint32_t a, uint32_t b) {
  return (a < b) ? a : b;
}

KV_QUANT_INLINE uint32_t float_to_bits(_Float16 value) {
  union { float f; uint32_t u; } v;
  v.f = (float)value;
  return v.u;
}

KV_QUANT_INLINE _Float16 bits_to_float(uint32_t value) {
  union { uint32_t u; float f; } v;
  v.u = value;
  return (_Float16)v.f;
}

KV_QUANT_INLINE _Float16 shfl_down_float(_Float16 value, uint32_t offset) {
  return bits_to_float((uint32_t)vx_shfl_down(
      float_to_bits(value), offset, NUM_THREADS - 1, 0));
}

KV_QUANT_INLINE _Float16 shfl_idx_float(_Float16 value, uint32_t index) {
  return bits_to_float((uint32_t)vx_shfl_idx(
      float_to_bits(value), index, NUM_THREADS - 1, 0));
}

KV_QUANT_INLINE void reduce_min_max(_Float16* min_v, _Float16* max_v, uint32_t lane) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const _Float16 other_min = shfl_down_float(*min_v, offset);
    const _Float16 other_max = shfl_down_float(*max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < *min_v) *min_v = other_min;
      if (other_max > *max_v) *max_v = other_max;
    }
  }
  *min_v = shfl_idx_float(*min_v, 0);
  *max_v = shfl_idx_float(*max_v, 0);
}

KV_QUANT_INLINE int32_t round_half_even(_Float16 value) {
  const int32_t truncated = (int32_t)value;
  const _Float16 truncated_f = (_Float16)truncated;
  const int32_t floor_value = truncated - (int32_t)(truncated_f > value);
  const _Float16 fraction = value - (_Float16)floor_value;
  const int32_t round_up = (int32_t)(fraction > 0.5f)
      | ((int32_t)(fraction == 0.5f) & (floor_value & 1));
  return floor_value + round_up;
}

KV_QUANT_INLINE void make_qparams(_Float16 min_v,
                                  _Float16 max_v,
                                  uint32_t quant_mode,
                                  fp16_t* scale_bits,
                                  _Float16* quant_scale,
                                  int16_t* zp_out) {
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const _Float16 abs_min = min_v < 0.0f ? -min_v : min_v;
    const _Float16 abs_max = max_v < 0.0f ? -max_v : max_v;
    _Float16 absmax = abs_min > abs_max ? abs_min : abs_max;
    if (absmax < 1e-8f) {
      absmax = 1e-8f;
    }
    const _Float16 scale = absmax / 7.5f;
    *scale_bits = kv_fp16_to_bits(scale);
    *quant_scale = scale;
    *zp_out = 0;
    return;
  }

  const _Float16 range = max_v - min_v;
  _Float16 scale =
      quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
  }

  int32_t zp;
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    zp = round_half_even(-min_v / scale) - 8;
  } else {
    zp = kv_round_half_away_from_zero_fp16(-min_v / scale);
    if (zp < 0) zp = 0;
    if (zp > 15) zp = 15;
  }
  *scale_bits = kv_fp16_to_bits(scale);
  *quant_scale =
      quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? kv_fp16_from_bits(*scale_bits)
          : scale;
  *zp_out = (int16_t)zp;
}

KV_QUANT_INLINE void make_qparams_float(_Float16 min_v,
                                        _Float16 max_v,
                                        uint32_t quant_mode,
                                        fp16_t* scale_bits,
                                        _Float16* quant_scale,
                                        _Float16* zero_out) {
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const _Float16 abs_min = min_v < 0.0f ? -min_v : min_v;
    const _Float16 abs_max = max_v < 0.0f ? -max_v : max_v;
    _Float16 absmax = abs_min > abs_max ? abs_min : abs_max;
    if (absmax < 1e-8f) absmax = 1e-8f;
    const _Float16 scale = absmax / 7.5f;
    *scale_bits = kv_fp16_to_bits(scale);
    *quant_scale = scale;
    *zero_out = 0.0f;
    return;
  }

  const _Float16 range = max_v - min_v;
  _Float16 scale =
      quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
  if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC && range != 0.0f)
      || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          && range / 15.0f > 1e-8f)) {
    scale = range / 15.0f;
  }

  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
    *zero_out = (_Float16)round_half_even(-min_v / scale) - 8.0f;
  } else {
    int32_t zero = kv_round_half_away_from_zero_fp16(-min_v / scale);
    if (zero < 0) zero = 0;
    if (zero > 15) zero = 15;
    *zero_out = (_Float16)zero;
  }
  *scale_bits = kv_fp16_to_bits(scale);
  *quant_scale =
      quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
          ? kv_fp16_from_bits(*scale_bits)
          : scale;
}

KV_QUANT_INLINE uint8_t quantize_value(_Float16 value,
                                       _Float16 scale,
                                       int16_t zero,
                                       uint32_t quant_mode) {
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return kv_quantize_value_scale_fp16(value, scale, zero);
  }
  int32_t q = round_half_even(value / scale) + (int32_t)zero;
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

KV_QUANT_INLINE uint8_t quantize_loaded_value(fp16_t value_bits,
                                              _Float16 scale,
                                              _Float16 zero,
                                              uint32_t quant_mode) {
  const _Float16 value = kv_fp16_from_bits(value_bits);
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    return kv_quantize_value_scale_fp16(value, scale, (int16_t)zero);
  }
  int32_t q = round_half_even(value / scale) + (int32_t)zero;
  if (q < -8) q = -8;
  if (q > 7) q = 7;
  return (uint8_t)(q & 0x0f);
}

static void compute_params_baseline(const fp16_t* src,
                                    uint32_t K,
                                    uint32_t N,
                                    uint32_t QBLK,
                                    uint32_t QDIR,
                                    uint32_t quant_mode,
                                    uint32_t k,
                                    uint32_t n,
                                    fp16_t* scale_bits_out,
                                    _Float16* quant_scale_out,
                                    int16_t* zp_out) {
  _Float16 min_v = kv_fp16_from_bits(src[(uint64_t)k * N + n]);
  _Float16 max_v = min_v;
  if (QDIR == 0) {
    const uint32_t k0 = (k / QBLK) * QBLK;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const _Float16 v = kv_fp16_from_bits(src[(uint64_t)kk * N + n]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n / QBLK) * QBLK;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const _Float16 v = kv_fp16_from_bits(src[(uint64_t)k * N + nn]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }
  make_qparams(min_v, max_v, quant_mode, scale_bits_out,
               quant_scale_out, zp_out);
}

static void quantize_baseline(kernel_arg_t* arg,
                              fp16_t* src,
                              uint8_t* dst,
                              fp16_t* scales,
                              int16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t total_bytes = K * (N >> 1);
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  for (uint32_t byte_idx = thread_id; byte_idx < total_bytes; byte_idx += total_threads) {
    const uint32_t k = byte_idx / (N >> 1);
    const uint32_t n_pair = byte_idx - k * (N >> 1);
    const uint32_t n0 = n_pair << 1;
    const uint32_t n1 = n0 + 1;
    fp16_t bits0, bits1;
    _Float16 scale0, scale1;
    int16_t zp0, zp1;
    compute_params_baseline(src, K, N, arg->QBLK, arg->QDIR,
                            arg->quant_mode, k, n0, &bits0, &scale0, &zp0);
    compute_params_baseline(src, K, N, arg->QBLK, arg->QDIR,
                            arg->quant_mode, k, n1, &bits1, &scale1, &zp1);
    const uint64_t qidx0 = kv_qparam_index(k, n0, K, N, arg->QBLK, arg->QDIR);
    const uint64_t qidx1 = kv_qparam_index(k, n1, K, N, arg->QBLK, arg->QDIR);
    scales[qidx0] = bits0;
    scales[qidx1] = bits1;
    zeros[qidx0] = zp0;
    zeros[qidx1] = zp1;
    const uint8_t q0 = quantize_value(
        kv_fp16_from_bits(src[(uint64_t)k * N + n0]), scale0, zp0,
        arg->quant_mode);
    const uint8_t q1 = quantize_value(
        kv_fp16_from_bits(src[(uint64_t)k * N + n1]), scale1, zp1,
        arg->quant_mode);
    kv_store_npair(dst, N, k, n_pair, q0, q1);
  }
}

static void quantize_qdir1_warp(kernel_arg_t* arg,
                                fp16_t* src,
                                uint8_t* dst,
                                fp16_t* scales,
                                int16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t groups_n = ceil_div_u32(N, arg->QBLK);
  const uint32_t tasks = K * groups_n;
  const uint32_t lane = threadIdx.x;
  for (uint32_t task = blockIdx.x; task < tasks; task += gridDim.x) {
    const uint32_t k = task / groups_n;
    const uint32_t group_n = task - k * groups_n;
    const uint32_t n0 = group_n * arg->QBLK;
    const uint32_t n1 = min_u32(n0 + arg->QBLK, N);
    _Float16 min_v = kv_fp16_from_bits(src[(uint64_t)k * N + n0]);
    _Float16 max_v = min_v;
    for (uint32_t n = n0 + lane; n < n1; n += NUM_THREADS) {
      const _Float16 v = kv_fp16_from_bits(src[(uint64_t)k * N + n]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
    reduce_min_max(&min_v, &max_v, lane);
    fp16_t scale_bits;
    _Float16 quant_scale;
    _Float16 zero;
    make_qparams_float(min_v, max_v, arg->quant_mode, &scale_bits,
                       &quant_scale, &zero);
    if (lane == 0) {
      const uint64_t qidx = (uint64_t)k * groups_n + group_n;
      scales[qidx] = scale_bits;
      zeros[qidx] = (int16_t)zero;
    }
    const uint32_t pairs = (n1 - n0) >> 1;
    for (uint32_t pair = lane; pair < pairs; pair += NUM_THREADS) {
      const uint32_t n = n0 + (pair << 1);
      const uint8_t q0 = quantize_loaded_value(
          src[(uint64_t)k * N + n], quant_scale, zero,
          arg->quant_mode);
      const uint8_t q1 = quantize_loaded_value(
          src[(uint64_t)k * N + n + 1], quant_scale, zero,
          arg->quant_mode);
      kv_store_npair(dst, N, k, n >> 1, q0, q1);
    }
  }
}

__attribute__((noinline))
static fp16_t single_group_float_to_fp16(_Float16 value) {
  return kv_fp16_to_bits(value);
}

__attribute__((noinline))
static void single_group_store_qparams(
    kernel_arg_t *__UNIFORM__ arg,
    _Float16 scale,
    _Float16 zero,
    uint32_t lane) {
  if (lane == 0) {
    auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
    auto zeros = reinterpret_cast<int16_t *>(arg->zero_addr);
    scales[0] = single_group_float_to_fp16(scale);
    zeros[0] = (int16_t)zero;
  }
}

// Decode updates with one token and one source quantization group are a
// common KV-cache shape. Keep this path separate from the generic task loop
// so normal and layout-fused quantization receive equivalent specialization
// opportunities without hard-coding a particular head dimension.
__attribute__((noinline))
static void quantize_qdir1_single_group_warp(
    kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  const uint32_t N = arg->N;
  const uint32_t lane = threadIdx.x;

  _Float16 min_v = kv_fp16_from_bits(src[0]);
  _Float16 max_v = min_v;
  for (uint32_t n = lane; n < N; n += NUM_THREADS) {
    const _Float16 value = kv_fp16_from_bits(src[n]);
    if (value < min_v) min_v = value;
    if (value > max_v) max_v = value;
  }
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const _Float16 other_min = shfl_down_float(min_v, offset);
    const _Float16 other_max = shfl_down_float(max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < min_v) min_v = other_min;
      if (other_max > max_v) max_v = other_max;
    }
  }
  min_v = shfl_idx_float(min_v, 0);
  max_v = shfl_idx_float(max_v, 0);

  const uint32_t quant_mode = arg->quant_mode;
  _Float16 scale;
  _Float16 zero;
  if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
    const _Float16 abs_min = min_v < 0.0f ? -min_v : min_v;
    const _Float16 abs_max = max_v < 0.0f ? -max_v : max_v;
    _Float16 absmax = abs_min > abs_max ? abs_min : abs_max;
    if (absmax < 1e-8f) absmax = 1e-8f;
    scale = absmax / 7.5f;
    zero = 0.0f;
  } else {
    const _Float16 range = max_v - min_v;
    scale =
        quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC ? 1.0f : 1e-8f;
    if ((quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
         && range != 0.0f)
        || (quant_mode != KV_QUANT_LEGACY_UINT4_ASYMMETRIC
            && range / 15.0f > 1e-8f)) {
      scale = range / 15.0f;
    }
    if (quant_mode == KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC) {
      zero = (_Float16)round_half_even(-min_v / scale) - 8.0f;
    } else {
      int32_t zp = kv_round_half_away_from_zero_fp16(-min_v / scale);
      if (zp < 0) zp = 0;
      if (zp > 15) zp = 15;
      zero = (_Float16)zp;
    }
  }
  _Float16 quant_scale = scale;
  if (quant_mode == KV_QUANT_LEGACY_UINT4_ASYMMETRIC) {
    quant_scale = kv_fp16_from_bits(kv_fp16_to_bits(scale));
  }
  single_group_store_qparams(arg, scale, zero, lane);

  for (uint32_t pair = lane; pair < (N >> 1); pair += NUM_THREADS) {
    const uint32_t n = pair << 1;
    const uint8_t q0 = quantize_loaded_value(
        src[n], quant_scale, zero, quant_mode);
    const uint8_t q1 = quantize_loaded_value(
        src[n + 1u], quant_scale, zero, quant_mode);
    dst[pair] = (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
  }
}

static void quantize_qdir1_thread_group(kernel_arg_t* arg,
                                        fp16_t* src,
                                        uint8_t* dst,
                                        fp16_t* scales,
                                        int16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t log2_qblk = arg->log2_qblk;
  const uint32_t groups_n =
      (N + arg->QBLK - 1u) >> log2_qblk;
  const uint32_t tasks = K * groups_n;
  const uint32_t total_threads = gridDim.x * blockDim.x;
  const uint32_t thread_id = blockIdx.x * blockDim.x + threadIdx.x;

  for (uint32_t task = thread_id; task < tasks; task += total_threads) {
    const uint32_t k = task / groups_n;
    const uint32_t group_n = task - k * groups_n;
    const uint32_t n0 = group_n << log2_qblk;
    const uint32_t n1 = min_u32(n0 + arg->QBLK, N);
    const fp16_t* row = src + (uint64_t)k * N;

    _Float16 min_v = kv_fp16_from_bits(row[n0]);
    _Float16 max_v = min_v;
    for (uint32_t n = n0 + 1u; n < n1; ++n) {
      const _Float16 value = kv_fp16_from_bits(row[n]);
      if (value < min_v) min_v = value;
      if (value > max_v) max_v = value;
    }

    fp16_t scale_bits;
    _Float16 quant_scale;
    _Float16 zero;
    make_qparams_float(min_v, max_v, arg->quant_mode, &scale_bits,
                       &quant_scale, &zero);
    scales[task] = scale_bits;
    zeros[task] = (int16_t)zero;

    uint8_t* dst_row = dst + (uint64_t)k * (N >> 1);
    for (uint32_t n = n0; n < n1; n += 2u) {
      const uint8_t q0 = quantize_loaded_value(
          row[n], quant_scale, zero, arg->quant_mode);
      const uint8_t q1 = quantize_loaded_value(
          row[n + 1u], quant_scale, zero, arg->quant_mode);
      dst_row[n >> 1] =
          (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
    }
  }
}

static void quantize_qdir0(kernel_arg_t* arg,
                           fp16_t* src,
                           uint8_t* dst,
                           fp16_t* scales,
                           int16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t groups_k = ceil_div_u32(K, arg->QBLK);
  const uint32_t n_pairs = N >> 1;
  const uint32_t tasks = groups_k * n_pairs;
  const uint32_t lane = threadIdx.x;
  for (uint32_t task = blockIdx.x; task < tasks; task += gridDim.x) {
    const uint32_t group_k = task / n_pairs;
    const uint32_t pair = task - group_k * n_pairs;
    const uint32_t n0 = pair << 1;
    const uint32_t n1 = n0 + 1;
    const uint32_t k0 = group_k * arg->QBLK;
    const uint32_t k1 = min_u32(k0 + arg->QBLK, K);
    _Float16 min0 = kv_fp16_from_bits(src[(uint64_t)k0 * N + n0]);
    _Float16 max0 = min0;
    _Float16 min1 = kv_fp16_from_bits(src[(uint64_t)k0 * N + n1]);
    _Float16 max1 = min1;
    for (uint32_t k = k0 + lane; k < k1; k += NUM_THREADS) {
      const _Float16 v0 = kv_fp16_from_bits(src[(uint64_t)k * N + n0]);
      const _Float16 v1 = kv_fp16_from_bits(src[(uint64_t)k * N + n1]);
      if (v0 < min0) min0 = v0;
      if (v0 > max0) max0 = v0;
      if (v1 < min1) min1 = v1;
      if (v1 > max1) max1 = v1;
    }
    reduce_min_max(&min0, &max0, lane);
    reduce_min_max(&min1, &max1, lane);
    fp16_t bits0, bits1;
    _Float16 scale0, scale1;
    _Float16 zero0, zero1;
    make_qparams_float(
        min0, max0, arg->quant_mode, &bits0, &scale0, &zero0);
    make_qparams_float(
        min1, max1, arg->quant_mode, &bits1, &scale1, &zero1);
    if (lane == 0) {
      const uint64_t base = (uint64_t)group_k * N;
      scales[base + n0] = bits0;
      scales[base + n1] = bits1;
      zeros[base + n0] = (int16_t)zero0;
      zeros[base + n1] = (int16_t)zero1;
    }
    for (uint32_t k = k0 + lane; k < k1; k += NUM_THREADS) {
      const uint8_t q0 = quantize_loaded_value(
          src[(uint64_t)k * N + n0], scale0, zero0,
          arg->quant_mode);
      const uint8_t q1 = quantize_loaded_value(
          src[(uint64_t)k * N + n1], scale1, zero1,
          arg->quant_mode);
      kv_store_npair(dst, N, k, pair, q0, q1);
    }
  }
}

void kernel_kv_cache_quant(kernel_arg_t *__UNIFORM__ arg) {
  auto src = reinterpret_cast<fp16_t *>(arg->src_addr);
  auto dst = reinterpret_cast<uint8_t *>(arg->dst_addr);
  auto scales = reinterpret_cast<fp16_t *>(arg->scale_addr);
  auto zeros = reinterpret_cast<int16_t *>(arg->zero_addr);
  if (arg->QDIR == 0) {
    quantize_qdir0(arg, src, dst, scales, zeros);
  } else if ((arg->QBLK & 1u) == 0u
             && arg->log2_qblk != UINT32_MAX) {
    if (arg->mapping_mode == KV_CACHE_QUANT_MAPPING_WARP_GROUP) {
      if (arg->K == 1u && arg->QBLK >= arg->N) {
        quantize_qdir1_single_group_warp(arg);
      } else {
        quantize_qdir1_warp(arg, src, dst, scales, zeros);
      }
    } else {
      quantize_qdir1_thread_group(arg, src, dst, scales, zeros);
    }
  } else {
    quantize_baseline(arg, src, dst, scales, zeros);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_KV_CACHE_QUANT_W4A16) kernel_kv_cache_quant(arg);
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) kernel_dispatcher(arg);
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
