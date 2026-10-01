#ifndef _SOFTMAX_SHUFFLE_CACHED_KERNEL_H_
#define _SOFTMAX_SHUFFLE_CACHED_KERNEL_H_

#include "fp16_output.h"
#include "warp_reduce_full.h"
#include "shuffle_output_overflow.h"
#include <VX_config.h>
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>

using data_t = fp16_t;


#ifndef SOFTMAX_REV2_SHUFFLE_UNROLL2
#define SOFTMAX_REV2_SHUFFLE_UNROLL2 0
#endif

#ifndef SOFTMAX_REV2_SHUFFLE_ADDR32
#define SOFTMAX_REV2_SHUFFLE_ADDR32 0
#endif

#ifndef SOFTMAX_REV2_SHUFFLE_GROUPED
#define SOFTMAX_REV2_SHUFFLE_GROUPED 0
#endif

#ifndef SOFTMAX_REV2_SHUFFLE_CURSOR
#define SOFTMAX_REV2_SHUFFLE_CURSOR 0
#endif

#ifndef SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
#define SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP SOFTMAX_REV2_SHUFFLE_CURSOR
#endif

static inline fp16_t output_fp16(float value) {
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  return softmax_probability_to_fp16(value);
#else
  return float_to_fp16(value);
#endif
}


static inline float input_float(fp16_t bits) {
  return fp16_to_float(bits);
}

// This family launches one warp per block. Partition LMEM evenly across all
// resident warps and recompute scores beyond the per-warp capacity from input,
// matching the bounded-cache strategy used by softmax/rev2_shuffle_grouped.
// Passing seq_len_k as the __local_mem stride lets the last resident warp run
// past LMEM whenever seq_len_k exceeds this capacity (32768 for C4).
static constexpr uint32_t kLocalScoreCapacity =
    ((LMEM_SIZE / NUM_WARPS / (uint32_t)sizeof(float))
      / NUM_THREADS) * NUM_THREADS;
static constexpr uint32_t kLocalScoreBytes =
    kLocalScoreCapacity * (uint32_t)sizeof(float);

static_assert(kLocalScoreCapacity != 0,
              "LMEM is too small for one warp of softmax scores");
static_assert(kLocalScoreBytes * NUM_WARPS <= LMEM_SIZE,
              "softmax score partitions exceed LMEM");

static inline uint32_t float_to_bits(float value) {
  union {
    float f;
    uint32_t u;
  } v;
  v.f = value;
  return v.u;
}

static inline float bits_to_float(uint32_t value) {
  union {
    uint32_t u;
    float f;
  } v;
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

static inline float warp_reduce_max(float value, uint32_t lane) {
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  return softmax_warp_max_full(value);
#else
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS && other > value) {
      value = other;
    }
  }
  return shfl_idx_float(value, 0);
#endif
}

static inline float warp_reduce_sum(float value, uint32_t lane) {
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  return softmax_warp_sum_full(value);
#else
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS) {
      value += other;
    }
  }
  return shfl_idx_float(value, 0);
#endif
}

template <typename Accessor>
static inline void softmax_shuffle_cached(const Accessor& accessor,
                                         uint32_t seq_len_k,
                                         uint32_t q,
                                         uint32_t use_mask,
                                         float scale,
                                         uint32_t lane) {
  const uint32_t k_end = use_mask && q + 1u < seq_len_k
      ? q + 1u
      : seq_len_k;
  auto scores = reinterpret_cast<float *>(
      __local_mem(kLocalScoreBytes));

  float local_max = VX_NEG_INF;
#if SOFTMAX_REV2_SHUFFLE_CURSOR && NUM_THREADS == TILE_DMA_MXU_NT
  const data_t *input = accessor.input + accessor.input_row_prefix + lane;
  for (uint32_t k = lane; k < k_end;
       k += NUM_THREADS, input += accessor.input_group_stride) {
    const float value = input_float(*input) * scale;
    if (k < kLocalScoreCapacity) scores[k] = value;
    if (value > local_max) local_max = value;
  }
#elif SOFTMAX_REV2_SHUFFLE_GROUPED && \
    NUM_THREADS == TILE_DMA_MXU_NT
  uint32_t load_group = 0;
  for (uint32_t k = lane; k < k_end;
       k += NUM_THREADS, ++load_group) {
    const uint32_t within_matrix =
        load_group * accessor.input_group_stride + lane;
    const float value = input_float(
        accessor.input[accessor.input_row_prefix + within_matrix]) * scale;
    if (k < kLocalScoreCapacity)
      scores[k] = value;
    if (value > local_max) local_max = value;
  }
#elif SOFTMAX_REV2_SHUFFLE_UNROLL2
  uint32_t load_k = lane;
  if (load_k < k_end) {
    const uint64_t load_offset = accessor.input_row_prefix
        + (uint64_t)(load_k >> 5) * accessor.input_group_stride
        + (load_k & 31u);
    data_t *load0 = accessor.input + load_offset;
    data_t *load1 = load0 + accessor.input_group_stride;
    const uint32_t two_group_stride = accessor.input_group_stride << 1;
    for (; load_k + NUM_THREADS < k_end; load_k += 2u * NUM_THREADS) {
      const float value0 = input_float(*load0) * scale;
      const float value1 = input_float(*load1) * scale;
      if (load_k < kLocalScoreCapacity)
        scores[load_k] = value0;
      if (load_k + NUM_THREADS < kLocalScoreCapacity)
        scores[load_k + NUM_THREADS] = value1;
      if (value0 > local_max) local_max = value0;
      if (value1 > local_max) local_max = value1;
      load0 += two_group_stride;
      load1 += two_group_stride;
    }
    if (load_k < k_end) {
      const float value = input_float(*load0) * scale;
      if (load_k < kLocalScoreCapacity)
        scores[load_k] = value;
      if (value > local_max) local_max = value;
    }
  }
#else
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float value = input_float(accessor.load(k)) * scale;
    if (k < kLocalScoreCapacity)
      scores[k] = value;
    if (value > local_max) {
      local_max = value;
    }
  }
#endif
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  __syncthreads();
#endif
  const float global_max = warp_reduce_max(local_max, lane);
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  vx_fence();
#endif

  float local_sum = 0.0f;
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  const uint32_t exp_end =
      (k_end + NUM_THREADS - 1u) & ~(NUM_THREADS - 1u);
  for (uint32_t k = lane; k < exp_end; k += NUM_THREADS) {
    const bool active = k < k_end;
    float value = global_max;
    if (active) {
      value = k < kLocalScoreCapacity
          ? scores[k] : input_float(accessor.load(k)) * scale;
    }
    // Keep the hardware exponential on a full warp even for causal tails.
    const float exp_value = vx_expf(value - global_max);
    if (active && k < kLocalScoreCapacity) scores[k] = exp_value;
    local_sum += active ? exp_value : 0.0f;
  }
#elif SOFTMAX_REV2_SHUFFLE_UNROLL2
  uint32_t exp_k = lane;
  for (; exp_k + NUM_THREADS < k_end; exp_k += 2u * NUM_THREADS) {
    const float value0 = exp_k < kLocalScoreCapacity
        ? scores[exp_k]
        : input_float(accessor.load(exp_k)) * scale;
    const float value1 = exp_k + NUM_THREADS < kLocalScoreCapacity
        ? scores[exp_k + NUM_THREADS]
        : input_float(accessor.load(exp_k + NUM_THREADS)) * scale;
    const float exp0 = vx_expf(value0 - global_max);
    const float exp1 = vx_expf(value1 - global_max);
    if (exp_k < kLocalScoreCapacity)
      scores[exp_k] = exp0;
    if (exp_k + NUM_THREADS < kLocalScoreCapacity)
      scores[exp_k + NUM_THREADS] = exp1;
    local_sum += exp0;
    local_sum += exp1;
  }
  if (exp_k < k_end) {
    const float value = exp_k < kLocalScoreCapacity
        ? scores[exp_k]
        : input_float(accessor.load(exp_k)) * scale;
    const float exp_value = vx_expf(value - global_max);
    if (exp_k < kLocalScoreCapacity)
      scores[exp_k] = exp_value;
    local_sum += exp_value;
  }
#else
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float value = k < kLocalScoreCapacity
        ? scores[k]
        : input_float(accessor.load(k)) * scale;
    const float exp_value = vx_expf(value - global_max);
    if (k < kLocalScoreCapacity)
      scores[k] = exp_value;
    local_sum += exp_value;
  }
#endif
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  __syncthreads();
#endif
  const float inv_sum = 1.0f / warp_reduce_sum(local_sum, lane);
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  vx_fence();
#endif

#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  if (k_end > kLocalScoreCapacity) {
    softmax_write_cache_overflow(accessor, scores, kLocalScoreCapacity,
        seq_len_k, k_end, scale, global_max, inv_sum, lane);
    __syncthreads();
    return;
  }
#endif

#if SOFTMAX_REV2_SHUFFLE_CURSOR && NUM_THREADS == TILE_DMA_MXU_KT
  data_t *output = accessor.output + accessor.output_row_prefix + lane;
  uint32_t k = lane;
  for (; k < k_end;
       k += NUM_THREADS, output += accessor.output_group_stride) {
    const float exp_value = k < kLocalScoreCapacity
        ? scores[k]
        : vx_expf(input_float(accessor.load(k)) * scale - global_max);
    *output = output_fp16(exp_value * inv_sum);
  }
  // Continue each lane's aligned sequence after its last active element.
  // Starting at k_end + lane misaligns the cursor on partial causal groups.
  for (; k < seq_len_k;
       k += NUM_THREADS, output += accessor.output_group_stride) {
    *output = float_to_fp16(0.0f);
  }
#elif SOFTMAX_REV2_SHUFFLE_GROUPED && \
    NUM_THREADS == TILE_DMA_MXU_KT
  uint32_t store_group = 0;
  for (uint32_t k = lane; k < k_end;
       k += NUM_THREADS, ++store_group) {
    const uint32_t within_matrix =
        store_group * accessor.output_group_stride + lane;
    const float exp_value = k < kLocalScoreCapacity
        ? scores[k]
        : vx_expf(input_float(accessor.load(k)) * scale - global_max);
    accessor.output[accessor.output_row_prefix + within_matrix] =
        output_fp16(exp_value * inv_sum);
  }
  uint32_t zero_k = k_end + lane;
  const uint32_t zero_lane = zero_k & 31u;
  uint32_t zero_group = zero_k >> 5;
  for (; zero_k < seq_len_k;
       zero_k += NUM_THREADS, ++zero_group) {
    const uint32_t within_matrix =
        zero_group * accessor.output_group_stride + zero_lane;
    accessor.output[accessor.output_row_prefix + within_matrix] =
        float_to_fp16(0.0f);
  }
#elif SOFTMAX_REV2_SHUFFLE_UNROLL2
  uint32_t store_k = lane;
  if (store_k < k_end) {
    const uint64_t store_offset = accessor.output_row_prefix
        + (uint64_t)(store_k >> 5) * accessor.output_group_stride
        + (store_k & 31u);
    data_t *store0 = accessor.output + store_offset;
    data_t *store1 = store0 + accessor.output_group_stride;
    const uint32_t two_group_stride = accessor.output_group_stride << 1;
    for (; store_k + NUM_THREADS < k_end; store_k += 2u * NUM_THREADS) {
      const float exp0 = store_k < kLocalScoreCapacity
          ? scores[store_k]
          : vx_expf(input_float(accessor.load(store_k)) * scale - global_max);
      const float exp1 = store_k + NUM_THREADS < kLocalScoreCapacity
          ? scores[store_k + NUM_THREADS]
          : vx_expf(input_float(accessor.load(store_k + NUM_THREADS)) * scale
                    - global_max);
      *store0 = output_fp16(exp0 * inv_sum);
      *store1 = output_fp16(exp1 * inv_sum);
      store0 += two_group_stride;
      store1 += two_group_stride;
    }
    if (store_k < k_end) {
      const float exp_value = store_k < kLocalScoreCapacity
          ? scores[store_k]
          : vx_expf(input_float(accessor.load(store_k)) * scale - global_max);
      *store0 = output_fp16(exp_value * inv_sum);
    }
  }
  uint32_t zero_k = k_end + lane;
  if (zero_k < seq_len_k) {
    const uint64_t zero_offset = accessor.output_row_prefix
        + (uint64_t)(zero_k >> 5) * accessor.output_group_stride
        + (zero_k & 31u);
    data_t *zero0 = accessor.output + zero_offset;
    data_t *zero1 = zero0 + accessor.output_group_stride;
    const uint32_t two_group_stride = accessor.output_group_stride << 1;
    for (; zero_k + NUM_THREADS < seq_len_k;
         zero_k += 2u * NUM_THREADS) {
      *zero0 = float_to_fp16(0.0f);
      *zero1 = float_to_fp16(0.0f);
      zero0 += two_group_stride;
      zero1 += two_group_stride;
    }
    if (zero_k < seq_len_k) {
      *zero0 = float_to_fp16(0.0f);
    }
  }
#else
  uint32_t k = lane;
  for (; k < k_end; k += NUM_THREADS) {
    const float exp_value = k < kLocalScoreCapacity
        ? scores[k]
        : vx_expf(input_float(accessor.load(k)) * scale - global_max);
    accessor.store(k, output_fp16(exp_value * inv_sum));
  }
#if !SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  k = k_end + lane;
#endif
  for (; k < seq_len_k; k += NUM_THREADS) {
    accessor.store(k, float_to_fp16(0.0f));
  }
#endif
#if SOFTMAX_REV2_SHUFFLE_FULL_WARP_EXP
  // A later row reuses this warp's score partition.
  __syncthreads();
#endif
}


#endif
