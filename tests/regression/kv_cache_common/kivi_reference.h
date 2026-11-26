#pragma once
#include "kv_cache_w4a16.h"
#include <algorithm>
#include <cmath>

static inline void kivi_reference_range(float low, float high, fp16_t& bits, int16_t& zp) {
  low = std::min(0.f, low);
  high = std::max(0.f, high);
  bits = std::max<fp16_t>(1, float_to_fp16_preserve(high == low ? 1.f : (high-low)/15.f));
  int q = int(std::nearbyint(-low/fp16_to_float_preserve(bits))) - 8;
  zp = std::clamp(q, -8, 7);
}
static inline uint8_t kivi_reference_code(float value, float scale, int zero) {
  return uint8_t(std::clamp(int(std::nearbyint(value/scale))+zero, -8, 7) & 15);
}
