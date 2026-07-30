#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_intrinsics.h>
#include <vx_math.h>
#include <vx_spawn.h>
#include <VX_config.h>

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

// This family launches one warp per block. Partition LMEM evenly across all
// resident warps and recompute scores beyond the per-warp capacity from input,
// matching the bounded-cache strategy used by softmax/rev2_shuffle_grouped.
// Passing seq_len_k as the __local_mem stride lets the last resident warp run
// past LMEM whenever seq_len_k exceeds this capacity (32768 for C4).
static constexpr uint32_t kLocalScoreCapacity =
    (((1u << LMEM_LOG_SIZE) / NUM_WARPS / (uint32_t)sizeof(float))
      / NUM_THREADS) * NUM_THREADS;
static constexpr uint32_t kLocalScoreBytes =
    kLocalScoreCapacity * (uint32_t)sizeof(float);

static_assert(kLocalScoreCapacity != 0,
              "LMEM is too small for one warp of softmax scores");
static_assert(kLocalScoreBytes * NUM_WARPS <= (1u << LMEM_LOG_SIZE),
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
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS && other > value) {
      value = other;
    }
  }
  return shfl_idx_float(value, 0);
}

static inline float warp_reduce_sum(float value, uint32_t lane) {
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    const float other = shfl_down_float(value, offset);
    if (lane + offset < NUM_THREADS) {
      value += other;
    }
  }
  return shfl_idx_float(value, 0);
}

struct TiledAccessor {
  data_t *input;
  data_t *output;
  uint64_t input_row_prefix;
  uint64_t output_row_prefix;
  uint32_t input_group_stride;
  uint32_t output_group_stride;
  uint32_t log2_mxu_nt;
  uint32_t log2_mxu_kt;
  uint32_t mxu_nt_mask;
  uint32_t mxu_kt_mask;

  data_t load(uint32_t k) const {
#if SOFTMAX_REV2_SHUFFLE_ADDR32
    const uint32_t within_matrix =
        (k >> 5) * input_group_stride + (k & 31u);
    const uint64_t offset = input_row_prefix + within_matrix;
#else
    const uint64_t offset = input_row_prefix
        + (uint64_t)(k >> log2_mxu_nt) * input_group_stride
        + (k & mxu_nt_mask);
#endif
    return input[offset];
  }

  void store(uint32_t k, data_t value) const {
#if SOFTMAX_REV2_SHUFFLE_ADDR32
    const uint32_t within_matrix =
        (k >> 5) * output_group_stride + (k & 31u);
    const uint64_t offset = output_row_prefix + within_matrix;
#else
    const uint64_t offset = output_row_prefix
        + (uint64_t)(k >> log2_mxu_kt) * output_group_stride
        + (k & mxu_kt_mask);
#endif
    output[offset] = value;
  }
};

static inline void softmax_tiled_shuffle(const TiledAccessor& accessor,
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
#if SOFTMAX_REV2_SHUFFLE_GROUPED && \
    NUM_THREADS == TILE_DMA_MXU_NT
  uint32_t load_group = 0;
  for (uint32_t k = lane; k < k_end;
       k += NUM_THREADS, ++load_group) {
    const uint32_t within_matrix =
        load_group * accessor.input_group_stride + lane;
    const float value = fp16_to_float(
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
      const float value0 = fp16_to_float(*load0) * scale;
      const float value1 = fp16_to_float(*load1) * scale;
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
      const float value = fp16_to_float(*load0) * scale;
      if (load_k < kLocalScoreCapacity)
        scores[load_k] = value;
      if (value > local_max) local_max = value;
    }
  }
#else
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float value = fp16_to_float(accessor.load(k)) * scale;
    if (k < kLocalScoreCapacity)
      scores[k] = value;
    if (value > local_max) {
      local_max = value;
    }
  }
#endif
  const float global_max = warp_reduce_max(local_max, lane);

  float local_sum = 0.0f;
#if SOFTMAX_REV2_SHUFFLE_UNROLL2
  uint32_t exp_k = lane;
  for (; exp_k + NUM_THREADS < k_end; exp_k += 2u * NUM_THREADS) {
    const float value0 = exp_k < kLocalScoreCapacity
        ? scores[exp_k]
        : fp16_to_float(accessor.load(exp_k)) * scale;
    const float value1 = exp_k + NUM_THREADS < kLocalScoreCapacity
        ? scores[exp_k + NUM_THREADS]
        : fp16_to_float(accessor.load(exp_k + NUM_THREADS)) * scale;
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
        : fp16_to_float(accessor.load(exp_k)) * scale;
    const float exp_value = vx_expf(value - global_max);
    if (exp_k < kLocalScoreCapacity)
      scores[exp_k] = exp_value;
    local_sum += exp_value;
  }
#else
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float value = k < kLocalScoreCapacity
        ? scores[k]
        : fp16_to_float(accessor.load(k)) * scale;
    const float exp_value = vx_expf(value - global_max);
    if (k < kLocalScoreCapacity)
      scores[k] = exp_value;
    local_sum += exp_value;
  }
#endif
  const float inv_sum = 1.0f / warp_reduce_sum(local_sum, lane);

#if SOFTMAX_REV2_SHUFFLE_GROUPED && \
    NUM_THREADS == TILE_DMA_MXU_KT
  uint32_t store_group = 0;
  for (uint32_t k = lane; k < k_end;
       k += NUM_THREADS, ++store_group) {
    const uint32_t within_matrix =
        store_group * accessor.output_group_stride + lane;
    const float exp_value = k < kLocalScoreCapacity
        ? scores[k]
        : vx_expf(fp16_to_float(accessor.load(k)) * scale - global_max);
    accessor.output[accessor.output_row_prefix + within_matrix] =
        float_to_fp16(exp_value * inv_sum);
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
          : vx_expf(fp16_to_float(accessor.load(store_k)) * scale - global_max);
      const float exp1 = store_k + NUM_THREADS < kLocalScoreCapacity
          ? scores[store_k + NUM_THREADS]
          : vx_expf(fp16_to_float(accessor.load(store_k + NUM_THREADS)) * scale
                    - global_max);
      *store0 = float_to_fp16(exp0 * inv_sum);
      *store1 = float_to_fp16(exp1 * inv_sum);
      store0 += two_group_stride;
      store1 += two_group_stride;
    }
    if (store_k < k_end) {
      const float exp_value = store_k < kLocalScoreCapacity
          ? scores[store_k]
          : vx_expf(fp16_to_float(accessor.load(store_k)) * scale - global_max);
      *store0 = float_to_fp16(exp_value * inv_sum);
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
  for (uint32_t k = lane; k < k_end; k += NUM_THREADS) {
    const float exp_value = k < kLocalScoreCapacity
        ? scores[k]
        : vx_expf(fp16_to_float(accessor.load(k)) * scale - global_max);
    accessor.store(k, float_to_fp16(exp_value * inv_sum));
  }
  for (uint32_t k = k_end + lane; k < seq_len_k; k += NUM_THREADS) {
    accessor.store(k, float_to_fp16(0.0f));
  }
#endif
}

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t rows_total =
      arg->batch_size * arg->num_heads * arg->seq_len_q;
  const uint32_t mt = 1u << arg->log2_mt;
  const uint32_t mxu_nt = 1u << arg->log2_mxu_nt;
  const uint32_t mxu_kt = 1u << arg->log2_mxu_kt;
  const uint64_t input_matrix_elems =
      (uint64_t)arg->M_pad * arg->seq_len_k_pad;
  const uint64_t output_matrix_elems =
      (uint64_t)arg->M_pad * arg->output_k_pad;

  for (uint32_t row_idx = blockIdx.x;
       row_idx < rows_total;
       row_idx += gridDim.x) {
    const uint32_t matrix_idx = row_idx / arg->seq_len_q;
    const uint32_t q = row_idx - matrix_idx * arg->seq_len_q;
    const uint32_t mt_idx = q >> arg->log2_mt;
    const uint32_t m0 = q & (mt - 1u);
    const uint32_t cm = min_u32(arg->M_pad - mt_idx * mt, mt);
    const uint64_t input_row_prefix =
        (uint64_t)mt_idx * mt * arg->seq_len_k_pad
        + (uint64_t)m0 * mxu_nt;
    const uint64_t output_row_prefix =
        (uint64_t)mt_idx * mt * arg->output_k_pad
        + (uint64_t)m0 * mxu_kt;

    TiledAccessor accessor = {
        reinterpret_cast<data_t *>(arg->input_addr)
            + batched_matrix_base(matrix_idx, input_matrix_elems),
        reinterpret_cast<data_t *>(arg->output_addr)
            + batched_matrix_base(matrix_idx, output_matrix_elems),
        input_row_prefix,
        output_row_prefix,
        cm * mxu_nt,
        cm * mxu_kt,
        arg->log2_mxu_nt,
        arg->log2_mxu_kt,
        mxu_nt - 1u,
        mxu_kt - 1u,
    };
    softmax_tiled_shuffle(accessor,
                          arg->seq_len_k,
                          q,
                          arg->use_mask,
                          arg->scale,
                          threadIdx.x);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  if (arg->kernel_id == KERNEL_SOFTMAX_LAYOUT_FUSED) {
    kernel_softmax_layout_fused(arg);
  }
}

static inline uint32_t effective_power_kernel_iterations(
    const kernel_arg_t *arg) {
  return arg->power_kernel_iterations == 0u
      ? 1u : arg->power_kernel_iterations;
}

void kernel_dispatcher_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_dispatcher(arg);
  }
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_dispatcher_power), arg);
}
