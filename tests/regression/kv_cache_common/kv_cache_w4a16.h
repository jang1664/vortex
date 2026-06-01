#ifndef _KV_CACHE_W4A16_COMMON_H_
#define _KV_CACHE_W4A16_COMMON_H_

#include "../vector_common/fp16.h"
#include <stdint.h>

static inline uint32_t ceil_div_u32(uint32_t a, uint32_t b) {
  return (a + b - 1u) / b;
}

static inline uint64_t kv_qparam_index(uint32_t k,
                                       uint32_t n,
                                       uint32_t K,
                                       uint32_t N,
                                       uint32_t QBLK,
                                       uint32_t QDIR) {
  (void)K;
  if (QDIR == 0) {
    return (uint64_t)(k / QBLK) * N + n;
  }
  return (uint64_t)k * ceil_div_u32(N, QBLK) + (n / QBLK);
}

static inline uint64_t kv_qparam_count(uint32_t K,
                                       uint32_t N,
                                       uint32_t QBLK,
                                       uint32_t QDIR) {
  if (QDIR == 0) {
    return (uint64_t)ceil_div_u32(K, QBLK) * N;
  }
  return (uint64_t)K * ceil_div_u32(N, QBLK);
}

static inline uint8_t kv_get_nibble(const uint8_t* packed,
                                    uint32_t K,
                                    uint32_t N,
                                    uint32_t k,
                                    uint32_t n) {
  (void)K;
  const uint8_t byte = packed[(uint64_t)k * (N >> 1) + (n >> 1)];
  return (n & 1u) ? (byte >> 4) : (byte & 0x0fu);
}

static inline uint8_t kv_quantize_value(float x, float scale, int16_t zp) {
  if (scale == 0.0f) {
    return 0;
  }
  float qf = x / scale + (float)zp;
  int32_t q = (int32_t)(qf + ((qf >= 0.0f) ? 0.5f : -0.5f));
  if (q < 0) q = 0;
  if (q > 15) q = 15;
  return (uint8_t)q;
}

static inline void kv_store_npair(uint8_t* packed,
                                  uint32_t N,
                                  uint32_t k,
                                  uint32_t n_pair,
                                  uint8_t q0,
                                  uint8_t q1) {
  packed[(uint64_t)k * (N >> 1) + n_pair] =
      (uint8_t)((q0 & 0x0fu) | ((q1 & 0x0fu) << 4));
}

#endif // _KV_CACHE_W4A16_COMMON_H_
