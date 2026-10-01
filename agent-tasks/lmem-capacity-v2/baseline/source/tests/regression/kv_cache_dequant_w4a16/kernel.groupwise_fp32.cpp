#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <VX_config.h>
#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define KV_DEQUANT_INLINE static inline __attribute__((always_inline))

template <uint32_t QUANT_MODE>
KV_DEQUANT_INLINE int32_t decode_int4(uint8_t bits) {
  return QUANT_MODE == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? (int32_t)bits
      : (int32_t)kv_signed_int4(bits);
}

template <uint32_t QUANT_MODE>
KV_DEQUANT_INLINE void load_qparam(const fp16_t* scales,
                                   const uint16_t* zeros,
                                   uint64_t qidx,
                                   float* scale,
                                   int32_t* zero) {
  *scale = fp16_to_float(scales[qidx]);
  *zero = QUANT_MODE == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
      ? 0
      : kv_signed_int16(zeros[qidx]);
}

template <uint32_t QUANT_MODE>
KV_DEQUANT_INLINE uint32_t dequantize_pair(uint8_t packed,
                                           float scale0,
                                           int32_t zero0,
                                           float scale1,
                                           int32_t zero1) {
  const int32_t q0 = decode_int4<QUANT_MODE>(packed & 0x0fu);
  const int32_t q1 = decode_int4<QUANT_MODE>(packed >> 4);
  const int32_t q0_minus_zero = q0 - zero0;
  const int32_t q1_minus_zero = q1 - zero1;
  const fp16_t out0 =
      float_to_fp16((float)q0_minus_zero * scale0);
  const fp16_t out1 =
      float_to_fp16((float)q1_minus_zero * scale1);
  return (uint32_t)out0 | ((uint32_t)out1 << 16);
}

KV_DEQUANT_INLINE uint32_t broadcast_u32(uint32_t value) {
  return (uint32_t)vx_shfl_idx(value, 0, NUM_THREADS - 1, 0);
}

KV_DEQUANT_INLINE float broadcast_float(float value) {
  union {
    float f;
    uint32_t u;
  } bits;
  bits.f = value;
  bits.u = broadcast_u32(bits.u);
  return bits.f;
}

// QDIR=0 groups along K.  A warp handles adjacent packed N pairs while every
// lane walks the complete runtime-sized K group.  Each lane therefore loads
// its two qparams once and reuses them for QBLK output rows.
template <uint32_t QUANT_MODE>
static void dequantize_qdir0(kernel_arg_t* arg,
                            const uint8_t* src,
                            uint32_t* dst,
                            const fp16_t* scales,
                            const uint16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t row_pairs = N >> 1;
  const uint32_t pair_chunks =
      (row_pairs + NUM_THREADS - 1u) / NUM_THREADS;
  const uint32_t k_groups = (K + QBLK - 1u) / QBLK;
  const uint32_t total_tasks = k_groups * pair_chunks;
  const uint32_t lane = threadIdx.x;

  for (uint32_t task = blockIdx.x; task < total_tasks; task += gridDim.x) {
    const uint32_t k_group = task / pair_chunks;
    const uint32_t pair_chunk = task - k_group * pair_chunks;
    const uint32_t n_pair = pair_chunk * NUM_THREADS + lane;
    if (n_pair >= row_pairs) {
      continue;
    }

    const uint32_t n0 = n_pair << 1;
    const uint64_t qparam_base = (uint64_t)k_group * N + n0;
    float scale0, scale1;
    int32_t zero0, zero1;
    load_qparam<QUANT_MODE>(
        scales, zeros, qparam_base, &scale0, &zero0);
    load_qparam<QUANT_MODE>(
        scales, zeros, qparam_base + 1u, &scale1, &zero1);

    const uint32_t k_begin = k_group * QBLK;
    const uint32_t k_end =
        (k_begin + QBLK < K) ? k_begin + QBLK : K;
    uint64_t pair_idx = (uint64_t)k_begin * row_pairs + n_pair;
    for (uint32_t k = k_begin; k < k_end; ++k) {
      dst[pair_idx] = dequantize_pair<QUANT_MODE>(
          src[pair_idx], scale0, zero0, scale1, zero1);
      pair_idx += row_pairs;
    }
  }
}

// QDIR=1 groups along N.  A warp owns one (K row, N group), broadcasts its
// single qparam, and writes adjacent packed pairs cooperatively.  Supported
// QBLKs are even, so no packed byte crosses a group boundary.
template <uint32_t QUANT_MODE>
static void dequantize_qdir1(kernel_arg_t* arg,
                            const uint8_t* src,
                            uint32_t* dst,
                            const fp16_t* scales,
                            const uint16_t* zeros) {
  const uint32_t K = arg->K;
  const uint32_t N = arg->N;
  const uint32_t QBLK = arg->QBLK;
  const uint32_t row_pairs = N >> 1;
  const uint32_t n_groups = (N + QBLK - 1u) / QBLK;
  const uint32_t total_tasks = K * n_groups;
  const uint32_t lane = threadIdx.x;

  for (uint32_t task = blockIdx.x; task < total_tasks; task += gridDim.x) {
    const uint32_t k = task / n_groups;
    const uint32_t n_group = task - k * n_groups;
    const uint32_t n_begin = n_group * QBLK;
    const uint32_t n_end =
        (n_begin + QBLK < N) ? n_begin + QBLK : N;
    const uint32_t pair_begin = n_begin >> 1;
    const uint32_t pair_count = (n_end - n_begin) >> 1;

    float scale = 0.0f;
    int32_t zero = 0;
    if (lane == 0) {
      const uint64_t qidx = (uint64_t)k * n_groups + n_group;
      load_qparam<QUANT_MODE>(scales, zeros, qidx, &scale, &zero);
    }
    scale = broadcast_float(scale);
    zero = (int32_t)broadcast_u32((uint32_t)zero);

    const uint64_t row_base = (uint64_t)k * row_pairs;
    for (uint32_t local_pair = lane;
         local_pair < pair_count;
         local_pair += NUM_THREADS) {
      const uint64_t pair_idx = row_base + pair_begin + local_pair;
      dst[pair_idx] = dequantize_pair<QUANT_MODE>(
          src[pair_idx], scale, zero, scale, zero);
    }
  }
}

template <uint32_t QUANT_MODE>
static void kernel_kv_cache_dequant_mode(kernel_arg_t* arg) {
  const auto src = reinterpret_cast<const uint8_t*>(arg->src_addr);
  auto dst = reinterpret_cast<uint32_t*>(arg->dst_addr);
  const auto scales = reinterpret_cast<const fp16_t*>(arg->scale_addr);
  const auto zeros = reinterpret_cast<const uint16_t*>(arg->zero_addr);
  (void)arg->WTRANS;

  if (arg->QDIR == 0) {
    dequantize_qdir0<QUANT_MODE>(arg, src, dst, scales, zeros);
  } else {
    dequantize_qdir1<QUANT_MODE>(arg, src, dst, scales, zeros);
  }
}

void kernel_kv_cache_dequant(kernel_arg_t* arg) {
  switch (arg->quant_mode) {
  case KV_QUANT_LEGACY_UINT4_ASYMMETRIC:
    kernel_kv_cache_dequant_mode<KV_QUANT_LEGACY_UINT4_ASYMMETRIC>(arg);
    break;
  case KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC:
    kernel_kv_cache_dequant_mode<KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC>(arg);
    break;
  default:
    kernel_kv_cache_dequant_mode<KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC>(arg);
    break;
  }
}

void kernel_dispatcher(kernel_arg_t* arg) {
  if (arg->kernel_id == KERNEL_KV_CACHE_DEQUANT_W4A16) {
    kernel_kv_cache_dequant(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t* arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
