#ifndef _SOFTMAX_SIMT_CACHED_KERNEL_H_
#define _SOFTMAX_SIMT_CACHED_KERNEL_H_

#include "../vector_common/fp16.h"
#include <stdint.h>
#include <vx_math.h>
#include <vx_spawn.h>

// Shared DMA-free softmax body used to isolate layout-addressing cost.
// Accessor::load/store are the only layout-dependent operations.
template <typename Accessor>
static inline void softmax_simt_cached(const Accessor& accessor,
                                       uint32_t seq_len_k,
                                       uint32_t output_k_extent,
                                       uint32_t q,
                                       uint32_t use_mask,
                                       float scale,
                                       uint32_t tid,
                                       uint32_t block_size) {
  const uint32_t k_end = use_mask && q + 1u < seq_len_k
      ? q + 1u
      : seq_len_k;
  const uint32_t score_bytes = seq_len_k * (uint32_t)sizeof(float);
  const uint32_t reduce_bytes = block_size * (uint32_t)sizeof(float);
  auto local_base = reinterpret_cast<uint8_t *>(
      __local_mem(score_bytes + reduce_bytes));
  auto scores = reinterpret_cast<float *>(local_base);
  auto reduce = reinterpret_cast<float *>(local_base + score_bytes);
  float local_max = VX_NEG_INF;
  accessor.begin_load(k_end);
  for (uint32_t k = tid; k < k_end; k += block_size) {
    float value = fp16_to_float(accessor.load(k)) * scale;
    scores[k] = value;
    if (value > local_max) {
      local_max = value;
    }
  }
  reduce[tid] = local_max;
  __syncthreads();

  for (uint32_t stride = block_size >> 1; stride > 0; stride >>= 1) {
    if (tid < stride && reduce[tid + stride] > reduce[tid]) {
      reduce[tid] = reduce[tid + stride];
    }
    __syncthreads();
  }
  const float global_max = reduce[0];
  __syncthreads();

  float local_sum = 0.0f;
  for (uint32_t k = tid; k < k_end; k += block_size) {
    const float exp_value = vx_expf(scores[k] - global_max);
    scores[k] = exp_value;
    local_sum += exp_value;
  }
  reduce[tid] = local_sum;
  __syncthreads();

  for (uint32_t stride = block_size >> 1; stride > 0; stride >>= 1) {
    if (tid < stride) {
      reduce[tid] += reduce[tid + stride];
    }
    __syncthreads();
  }
  const float inv_sum = 1.0f / reduce[0];
  accessor.begin_store(0, k_end);
  for (uint32_t k = tid; k < k_end; k += block_size) {
    accessor.store(k, float_to_fp16(scores[k] * inv_sum));
  }
  accessor.begin_store(k_end, output_k_extent);
  for (uint32_t k = k_end + tid; k < output_k_extent; k += block_size) {
    accessor.store(k, float_to_fp16(0.0f));
  }
  // Keep all lanes synchronized before a power-test iteration can reuse LMEM.
  __syncthreads();
}

#endif  // _SOFTMAX_SIMT_CACHED_KERNEL_H_
