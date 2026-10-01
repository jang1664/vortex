#ifndef _SOFTMAX_WARP_REDUCE_FULL_H_
#define _SOFTMAX_WARP_REDUCE_FULL_H_

#include <VX_config.h>
#include <vx_intrinsics.h>
#include <stdint.h>

static inline float softmax_exchange_xor(float value, uint32_t offset) {
  union { float f; uint32_t u; } bits;
  bits.f = value;
  bits.u = (uint32_t)vx_shfl_bfly(bits.u, offset, NUM_THREADS - 1, 0);
  return bits.f;
}

// Every lane participates in every reduction step and receives the result.
// This avoids conditional lane updates followed by a lane-zero broadcast.
static inline float softmax_warp_max_full(float value) {
  for (uint32_t offset = NUM_THREADS >> 1; offset; offset >>= 1) {
    value = __builtin_fmaxf(value, softmax_exchange_xor(value, offset));
  }
  return value;
}

static inline float softmax_warp_sum_full(float value) {
  for (uint32_t offset = NUM_THREADS >> 1; offset; offset >>= 1) {
    value += softmax_exchange_xor(value, offset);
  }
  return value;
}

#endif
