#ifndef _SOFTMAX_SHUFFLE_OUTPUT_OVERFLOW_H_
#define _SOFTMAX_SHUFFLE_OUTPUT_OVERFLOW_H_

#include "fp16_output.h"
#include <VX_config.h>
#include <vx_math.h>

// The cache capacity is warp-aligned. Beyond it, recompute exponentials with
// all lanes active, including the final partial group; write logical elements
// only and preserve physical padding.
template <typename Accessor>
static inline void softmax_write_cache_overflow(
    const Accessor& accessor, const float* scores, uint32_t capacity,
    uint32_t seq_len_k, uint32_t k_end, float scale, float global_max,
    float inv_sum, uint32_t lane) {
  const uint32_t rounded_end = (k_end + NUM_THREADS - 1u) & ~(NUM_THREADS - 1u);
  uint32_t k = lane;
  for (; k < rounded_end; k += NUM_THREADS) {
    float exp_value;
    if (k < capacity) {
      exp_value = scores[k];
    } else {
      const float value = k < k_end
          ? fp16_to_float(accessor.load(k)) * scale : global_max;
      exp_value = vx_expf(value - global_max);
    }
    if (k < k_end) accessor.store(k, softmax_probability_to_fp16(exp_value * inv_sum));
    else if (k < seq_len_k) accessor.store(k, 0);
  }
  for (; k < seq_len_k; k += NUM_THREADS) accessor.store(k, 0);
}

#endif
