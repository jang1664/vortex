#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

static inline uint32_t min_u32(uint32_t a, uint32_t b) {
  return (a < b) ? a : b;
}

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

static inline void reduce_min_max(float* min_v, float* max_v, uint32_t lane) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other_min = shfl_down_float(*min_v, offset);
    const float other_max = shfl_down_float(*max_v, offset);
    if (lane + offset < NUM_THREADS) {
      if (other_min < *min_v) *min_v = other_min;
      if (other_max > *max_v) *max_v = other_max;
    }
  }
  *min_v = shfl_idx_float(*min_v, 0);
  *max_v = shfl_idx_float(*max_v, 0);
}

static inline void make_qparams(float min_v,
                                float max_v,
                                fp16_t* scale_bits,
                                float* inv_scale,
                                int16_t* zp_out) {
  const float range = max_v - min_v;
  float scale = 1.0f;
  float inv_for_zp = 1.0f;
  if (range != 0.0f) {
    scale = range / 15.0f;
    inv_for_zp = 15.0f / range;
  }
  int32_t zp = kv_round_half_away_from_zero(-min_v * inv_for_zp);
  if (zp < 0) zp = 0;
  if (zp > 15) zp = 15;
  *scale_bits = float_to_fp16(scale);
  const float stored_scale = fp16_to_float(*scale_bits);
  *inv_scale = (stored_scale == 0.0f) ? 0.0f : (1.0f / stored_scale);
  *zp_out = (int16_t)zp;
}

static void compute_params_baseline(const fp16_t* src,
                                    uint32_t K,
                                    uint32_t N,
                                    uint32_t QBLK,
                                    uint32_t QDIR,
                                    uint32_t k,
                                    uint32_t n,
                                    float* scale_out,
                                    int16_t* zp_out) {
  float min_v = fp16_to_float(src[(uint64_t)k * N + n]);
  float max_v = min_v;
  if (QDIR == 0) {
    const uint32_t k0 = (k / QBLK) * QBLK;
    const uint32_t k1 = min_u32(k0 + QBLK, K);
    for (uint32_t kk = k0; kk < k1; ++kk) {
      const float v = fp16_to_float(src[(uint64_t)kk * N + n]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  } else {
    const uint32_t n0 = (n / QBLK) * QBLK;
    const uint32_t n1 = min_u32(n0 + QBLK, N);
    for (uint32_t nn = n0; nn < n1; ++nn) {
      const float v = fp16_to_float(src[(uint64_t)k * N + nn]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
  }
  fp16_t scale_bits;
  float inv_scale;
  make_qparams(min_v, max_v, &scale_bits, &inv_scale, zp_out);
  (void)inv_scale;
  *scale_out = fp16_to_float(scale_bits);
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
    float scale0, scale1;
    int16_t zp0, zp1;
    compute_params_baseline(src, K, N, arg->QBLK, arg->QDIR, k, n0, &scale0, &zp0);
    compute_params_baseline(src, K, N, arg->QBLK, arg->QDIR, k, n1, &scale1, &zp1);
    const uint64_t qidx0 = kv_qparam_index(k, n0, K, N, arg->QBLK, arg->QDIR);
    const uint64_t qidx1 = kv_qparam_index(k, n1, K, N, arg->QBLK, arg->QDIR);
    const fp16_t bits0 = float_to_fp16(scale0);
    const fp16_t bits1 = float_to_fp16(scale1);
    const float stored0 = fp16_to_float(bits0);
    const float stored1 = fp16_to_float(bits1);
    scales[qidx0] = bits0;
    scales[qidx1] = bits1;
    zeros[qidx0] = zp0;
    zeros[qidx1] = zp1;
    const uint8_t q0 = kv_quantize_value_inv_scale(
        fp16_to_float(src[(uint64_t)k * N + n0]), 1.0f / stored0, zp0);
    const uint8_t q1 = kv_quantize_value_inv_scale(
        fp16_to_float(src[(uint64_t)k * N + n1]), 1.0f / stored1, zp1);
    kv_store_npair(dst, N, k, n_pair, q0, q1);
  }
}

static void quantize_qdir1(kernel_arg_t* arg,
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
    float min_v = 3.402823466e+38F;
    float max_v = -3.402823466e+38F;
    for (uint32_t n = n0 + lane; n < n1; n += NUM_THREADS) {
      const float v = fp16_to_float(src[(uint64_t)k * N + n]);
      if (v < min_v) min_v = v;
      if (v > max_v) max_v = v;
    }
    reduce_min_max(&min_v, &max_v, lane);
    fp16_t scale_bits;
    float inv_scale;
    int16_t zp;
    make_qparams(min_v, max_v, &scale_bits, &inv_scale, &zp);
    if (lane == 0) {
      const uint64_t qidx = (uint64_t)k * groups_n + group_n;
      scales[qidx] = scale_bits;
      zeros[qidx] = zp;
    }
    const uint32_t pairs = (n1 - n0) >> 1;
    for (uint32_t pair = lane; pair < pairs; pair += NUM_THREADS) {
      const uint32_t n = n0 + (pair << 1);
      const uint8_t q0 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n]), inv_scale, zp);
      const uint8_t q1 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n + 1]), inv_scale, zp);
      kv_store_npair(dst, N, k, n >> 1, q0, q1);
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
    float min0 = 3.402823466e+38F, max0 = -3.402823466e+38F;
    float min1 = 3.402823466e+38F, max1 = -3.402823466e+38F;
    for (uint32_t k = k0 + lane; k < k1; k += NUM_THREADS) {
      const float v0 = fp16_to_float(src[(uint64_t)k * N + n0]);
      const float v1 = fp16_to_float(src[(uint64_t)k * N + n1]);
      if (v0 < min0) min0 = v0;
      if (v0 > max0) max0 = v0;
      if (v1 < min1) min1 = v1;
      if (v1 > max1) max1 = v1;
    }
    reduce_min_max(&min0, &max0, lane);
    reduce_min_max(&min1, &max1, lane);
    fp16_t bits0, bits1;
    float inv0, inv1;
    int16_t zp0, zp1;
    make_qparams(min0, max0, &bits0, &inv0, &zp0);
    make_qparams(min1, max1, &bits1, &inv1, &zp1);
    if (lane == 0) {
      const uint64_t base = (uint64_t)group_k * N;
      scales[base + n0] = bits0;
      scales[base + n1] = bits1;
      zeros[base + n0] = zp0;
      zeros[base + n1] = zp1;
    }
    for (uint32_t k = k0 + lane; k < k1; k += NUM_THREADS) {
      const uint8_t q0 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n0]), inv0, zp0);
      const uint8_t q1 = kv_quantize_value_inv_scale(
          fp16_to_float(src[(uint64_t)k * N + n1]), inv1, zp1);
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
  } else if ((arg->QBLK & 1u) == 0u) {
    quantize_qdir1(arg, src, dst, scales, zeros);
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
