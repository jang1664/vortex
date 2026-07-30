#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"
#include <VX_config.h>
#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define DEQUANT_HBM_INLINE static inline __attribute__((always_inline))

#if defined(DEQUANT_HBM_ARITH_FP16)
using dequant_arith_t = _Float16;

DEQUANT_HBM_INLINE dequant_arith_t scale_from_bits(fp16_t bits) {
  return kv_fp16_from_bits(bits);
}

DEQUANT_HBM_INLINE fp16_t result_to_bits(dequant_arith_t value) {
  return kv_fp16_to_bits(value);
}
#else
using dequant_arith_t = float;

DEQUANT_HBM_INLINE dequant_arith_t scale_from_bits(fp16_t bits) {
  return fp16_to_float(bits);
}

DEQUANT_HBM_INLINE fp16_t result_to_bits(dequant_arith_t value) {
  return float_to_fp16(value);
}
#endif

template <uint32_t QUANT_MODE>
DEQUANT_HBM_INLINE int32_t decode_int4(uint8_t bits) {
  return QUANT_MODE == KV_QUANT_LEGACY_UINT4_ASYMMETRIC
      ? (int32_t)bits
      : (int32_t)kv_signed_int4(bits);
}

template <uint32_t QUANT_MODE>
DEQUANT_HBM_INLINE int32_t zero_from_bits(uint16_t bits) {
  return QUANT_MODE == KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC
      ? 0
      : kv_signed_int16(bits);
}

template <uint32_t QUANT_MODE>
DEQUANT_HBM_INLINE uint32_t dequantize_pair(uint8_t packed,
                                            dequant_arith_t scale0,
                                            int32_t zero0,
                                            dequant_arith_t scale1,
                                            int32_t zero1) {
  const int32_t q0 = decode_int4<QUANT_MODE>(packed & 0x0fu);
  const int32_t q1 = decode_int4<QUANT_MODE>(packed >> 4);
  const fp16_t out0 = result_to_bits(
      (dequant_arith_t)(q0 - zero0) * scale0);
  const fp16_t out1 = result_to_bits(
      (dequant_arith_t)(q1 - zero1) * scale1);
  return (uint32_t)out0 | ((uint32_t)out1 << 16);
}

DEQUANT_HBM_INLINE uint32_t memory_mix(uint8_t packed,
                                       fp16_t scale0,
                                       uint16_t zero0,
                                       fp16_t scale1,
                                       uint16_t zero1) {
  uint32_t value = (uint32_t)packed;
  value ^= (uint32_t)scale0 << 8;
  value ^= (uint32_t)zero0 << 16;
  value ^= ((uint32_t)scale1 << 1) | ((uint32_t)scale1 >> 15);
  return value ^ ((uint32_t)zero1 << 17) ^ ((uint32_t)zero1 >> 15);
}

DEQUANT_HBM_INLINE uint32_t broadcast_u32(uint32_t value) {
  return (uint32_t)vx_shfl_idx(value, 0, NUM_THREADS - 1, 0);
}

DEQUANT_HBM_INLINE dequant_arith_t broadcast_arith(dequant_arith_t value) {
  union {
    float f;
    uint32_t u;
  } bits;
  bits.f = (float)value;
  bits.u = broadcast_u32(bits.u);
  return (dequant_arith_t)bits.f;
}

template <uint32_t MODE, uint32_t QUANT_MODE>
static void run_qdir0(kernel_arg_t* arg,
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

  uint8_t compute_packed = 0;
  fp16_t compute_scale_bits = 0;
  uint16_t compute_zero_bits = 0;
  if (MODE == DEQUANT_HBM_COMPUTE) {
    compute_packed = src[lane & 0u];
    compute_scale_bits = scales[lane & 0u];
    if (QUANT_MODE != KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
      compute_zero_bits = zeros[lane & 0u];
    }
  }
  uint32_t checksum = 0;

  for (uint32_t task = blockIdx.x; task < total_tasks; task += gridDim.x) {
    const uint32_t k_group = task / pair_chunks;
    const uint32_t pair_chunk = task - k_group * pair_chunks;
    const uint32_t n_pair = pair_chunk * NUM_THREADS + lane;
    if (n_pair >= row_pairs) {
      continue;
    }

    const uint32_t n0 = n_pair << 1;
    const uint64_t qparam_base = (uint64_t)k_group * N + n0;
    fp16_t scale0_bits = compute_scale_bits;
    fp16_t scale1_bits = compute_scale_bits;
    uint16_t zero0_bits = compute_zero_bits;
    uint16_t zero1_bits = compute_zero_bits;
    if (MODE == DEQUANT_HBM_FULL || MODE == DEQUANT_HBM_MEMORY) {
      scale0_bits = scales[qparam_base];
      scale1_bits = scales[qparam_base + 1u];
      if (QUANT_MODE != KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
        zero0_bits = zeros[qparam_base];
        zero1_bits = zeros[qparam_base + 1u];
      }
    }
    const dequant_arith_t scale0 = scale_from_bits(scale0_bits);
    const dequant_arith_t scale1 = scale_from_bits(scale1_bits);
    const int32_t zero0 = zero_from_bits<QUANT_MODE>(zero0_bits);
    const int32_t zero1 = zero_from_bits<QUANT_MODE>(zero1_bits);

    const uint32_t k_begin = k_group * QBLK;
    const uint32_t k_end =
        (k_begin + QBLK < K) ? k_begin + QBLK : K;
    uint64_t pair_idx = (uint64_t)k_begin * row_pairs + n_pair;
    for (uint32_t k = k_begin; k < k_end; ++k) {
      if (MODE == DEQUANT_HBM_FULL) {
        const uint8_t packed = src[pair_idx];
        dst[pair_idx] = dequantize_pair<QUANT_MODE>(
            packed, scale0, zero0, scale1, zero1);
      } else if (MODE == DEQUANT_HBM_MEMORY) {
        const uint8_t packed = src[pair_idx];
        dst[pair_idx] = memory_mix(
            packed, scale0_bits, zero0_bits, scale1_bits, zero1_bits);
      } else if (MODE == DEQUANT_HBM_COMPUTE) {
        const uint8_t packed = compute_packed ^ (uint8_t)pair_idx;
        checksum ^= dequantize_pair<QUANT_MODE>(
            packed, scale0, zero0, scale1, zero1) + k;
      } else {
        checksum ^= (uint32_t)pair_idx + k;
      }
      pair_idx += row_pairs;
    }
  }

  if ((MODE == DEQUANT_HBM_COMPUTE || MODE == DEQUANT_HBM_CONTROL)
      && lane == 0) {
    dst[blockIdx.x] = checksum;
  }
}

template <uint32_t MODE, uint32_t QUANT_MODE>
static void run_qdir1(kernel_arg_t* arg,
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

  uint8_t compute_packed = 0;
  fp16_t compute_scale_bits = 0;
  uint16_t compute_zero_bits = 0;
  if (MODE == DEQUANT_HBM_COMPUTE) {
    compute_packed = src[lane & 0u];
    compute_scale_bits = scales[lane & 0u];
    if (QUANT_MODE != KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
      compute_zero_bits = zeros[lane & 0u];
    }
  }
  uint32_t checksum = 0;

  for (uint32_t task = blockIdx.x; task < total_tasks; task += gridDim.x) {
    const uint32_t k = task / n_groups;
    const uint32_t n_group = task - k * n_groups;
    const uint32_t n_begin = n_group * QBLK;
    const uint32_t n_end =
        (n_begin + QBLK < N) ? n_begin + QBLK : N;
    const uint32_t pair_begin = n_begin >> 1;
    const uint32_t pair_count = (n_end - n_begin) >> 1;

    fp16_t scale_bits = 0;
    uint16_t zero_bits = compute_zero_bits;
    dequant_arith_t scale = (dequant_arith_t)0.0f;
    if (MODE == DEQUANT_HBM_MEMORY && lane == 0) {
      const uint64_t qidx = (uint64_t)k * n_groups + n_group;
      scale_bits = scales[qidx];
      if (QUANT_MODE != KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
        zero_bits = zeros[qidx];
      }
    } else if (MODE == DEQUANT_HBM_FULL && lane == 0) {
      const uint64_t qidx = (uint64_t)k * n_groups + n_group;
      scale = scale_from_bits(scales[qidx]);
      if (QUANT_MODE != KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC) {
        zero_bits = zeros[qidx];
      }
    } else if (MODE == DEQUANT_HBM_COMPUTE && lane == 0) {
      scale = scale_from_bits(compute_scale_bits);
    }
    if (MODE == DEQUANT_HBM_MEMORY) {
      scale_bits = (fp16_t)broadcast_u32((uint32_t)scale_bits);
    } else {
      scale = broadcast_arith(scale);
    }
    zero_bits = (uint16_t)broadcast_u32((uint32_t)zero_bits);
    const int32_t zero = zero_from_bits<QUANT_MODE>(zero_bits);

    const uint64_t row_base = (uint64_t)k * row_pairs;
    for (uint32_t local_pair = lane;
         local_pair < pair_count;
         local_pair += NUM_THREADS) {
      const uint64_t pair_idx = row_base + pair_begin + local_pair;
      if (MODE == DEQUANT_HBM_FULL) {
        const uint8_t packed = src[pair_idx];
        dst[pair_idx] = dequantize_pair<QUANT_MODE>(
            packed, scale, zero, scale, zero);
      } else if (MODE == DEQUANT_HBM_MEMORY) {
        const uint8_t packed = src[pair_idx];
        dst[pair_idx] = memory_mix(
            packed, scale_bits, zero_bits, scale_bits, zero_bits);
      } else if (MODE == DEQUANT_HBM_COMPUTE) {
        const uint8_t packed = compute_packed ^ (uint8_t)pair_idx;
        checksum ^= dequantize_pair<QUANT_MODE>(
            packed, scale, zero, scale, zero) + local_pair;
      } else {
        checksum ^= (uint32_t)pair_idx + local_pair;
      }
    }
  }

  if ((MODE == DEQUANT_HBM_COMPUTE || MODE == DEQUANT_HBM_CONTROL)
      && lane == 0) {
    dst[blockIdx.x] = checksum;
  }
}

template <uint32_t MODE, uint32_t QUANT_MODE>
static void run_mode(kernel_arg_t* arg, uint32_t copy) {
  const auto src = reinterpret_cast<const uint8_t*>(
      arg->src_addr + (uint64_t)copy * arg->src_stride);
  auto dst = reinterpret_cast<uint32_t*>(
      arg->dst_addr + (uint64_t)copy * arg->dst_stride);
  const auto scales = reinterpret_cast<const fp16_t*>(
      arg->scale_addr + (uint64_t)copy * arg->scale_stride);
  const auto zeros = reinterpret_cast<const uint16_t*>(
      arg->zero_addr + (uint64_t)copy * arg->zero_stride);

  if (arg->QDIR == 0) {
    run_qdir0<MODE, QUANT_MODE>(arg, src, dst, scales, zeros);
  } else {
    run_qdir1<MODE, QUANT_MODE>(arg, src, dst, scales, zeros);
  }
}

template <uint32_t MODE>
static void run_quant_mode(kernel_arg_t* arg, uint32_t copy) {
  switch (arg->quant_mode) {
  case KV_QUANT_LEGACY_UINT4_ASYMMETRIC:
    run_mode<MODE, KV_QUANT_LEGACY_UINT4_ASYMMETRIC>(arg, copy);
    break;
  case KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC:
    run_mode<MODE, KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC>(arg, copy);
    break;
  default:
    run_mode<MODE, KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC>(arg, copy);
    break;
  }
}

static void kernel_dequant_hbm_energy(kernel_arg_t* arg, uint32_t copy) {
  switch (arg->mode) {
  case DEQUANT_HBM_FULL:
    run_quant_mode<DEQUANT_HBM_FULL>(arg, copy);
    break;
  case DEQUANT_HBM_MEMORY:
    run_quant_mode<DEQUANT_HBM_MEMORY>(arg, copy);
    break;
  case DEQUANT_HBM_COMPUTE:
    run_quant_mode<DEQUANT_HBM_COMPUTE>(arg, 0);
    break;
  default:
    run_quant_mode<DEQUANT_HBM_CONTROL>(arg, 0);
    break;
  }
}

DEQUANT_HBM_INLINE uint32_t effective_power_kernel_iterations(
    const kernel_arg_t* arg) {
  return arg->power_kernel_iterations == 0u
      ? 1u
      : arg->power_kernel_iterations;
}

static void kernel_dispatcher_power(kernel_arg_t* arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  const uint32_t copies = arg->buffer_copies == 0u ? 1u : arg->buffer_copies;
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dequant_hbm_energy(arg, power_iter % copies);
  }
}

int main() {
  auto arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher_power, arg);
}
