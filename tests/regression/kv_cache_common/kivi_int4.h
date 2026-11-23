#pragma once
#include "kv_cache_w4a16.h"

// Include zero in the affine range. This keeps the signed zero point in
// [-8,7] even when the first token in a channel is the only valid sample.
struct kivi_params {
  fp16_t scale;
  int zero;
};

static inline int kivi_round(float x) {
  const int i = (int)x;
  const float tail = x - (float)i;
  return i + (tail > 0.5f || (tail == 0.5f && (i & 1)))
           - (tail < -0.5f || (tail == -0.5f && (i & 1)));
}

template <typename Load>
static inline kivi_params kivi_range(unsigned count, Load load) {
  float lo = 0, hi = 0;
  for (unsigned i = 0; i < count; ++i) {
    float v = fp16_to_float_preserve(load(i));
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  fp16_t bits = float_to_fp16_preserve(hi == lo ? 1.f : (hi-lo)/15.f);
  if (!bits) bits = 1;
  int z = kivi_round(-lo / fp16_to_float_preserve(bits)) - 8;
  return {bits, z < -8 ? -8 : (z > 7 ? 7 : z)};
}

static inline unsigned kivi_code(fp16_t x, kivi_params p) {
  int q = kivi_round(fp16_to_float_preserve(x) / fp16_to_float_preserve(p.scale)) + p.zero;
  return (unsigned)(q < -8 ? -8 : (q > 7 ? 7 : q)) & 15;
}

// Decode retains only the in-progress FP16 group for the next quantization.
// Each worker writes the same channel pair it subsequently reads.
static inline void kivi_stage_token(uint64_t fresh_addr, uint64_t scratch_addr, unsigned pitch,
                                    unsigned count, unsigned dim, unsigned worker, unsigned workers) {
  if (!fresh_addr) return;
  auto fresh = reinterpret_cast<const fp16_t*>(fresh_addr);
  auto row = reinterpret_cast<fp16_t*>(scratch_addr) + (count-1)*pitch;
  for (unsigned pair=worker; pair<dim/2; pair+=workers) {
    row[2*pair] = fresh[2*pair];
    row[2*pair+1] = fresh[2*pair+1];
  }
}

// Each work item owns complete packed bytes. Key groups cover up to 32
// token rows in two adjacent channels. Value groups cover 32 channels.
template <typename Load, typename StoreParam, typename StoreByte>
static inline void kivi_quant_groups(unsigned rows, unsigned cols, bool key,
    unsigned worker, unsigned workers, Load load, StoreParam param, StoreByte byte) {
  if (key) {
    const unsigned pairs = cols/2;
    const unsigned work = ((rows+31)/32)*pairs;
    for (unsigned item=worker; item<work; item+=workers) {
      const unsigned start = (item/pairs)*32, n = (item%pairs)*2;
      const unsigned count = rows-start < 32 ? rows-start : 32;
      auto lo = kivi_range(count, [&](unsigned t){return load(start+t,n);});
      auto hi = kivi_range(count, [&](unsigned t){return load(start+t,n+1);});
      param(start,n,lo);
      param(start,n+1,hi);
      for (unsigned t=0; t<count; ++t)
        byte(start+t,n,kivi_code(load(start+t,n),lo) | (kivi_code(load(start+t,n+1),hi)<<4));
    }
  } else {
    const unsigned groups = cols/32;
    for (unsigned item=worker; item<rows*groups; item+=workers) {
      const unsigned row=item/groups, n=(item%groups)*32;
      auto p = kivi_range(32, [&](unsigned lane){return load(row,n+lane);});
      param(row,n,p);
      for (unsigned i=0; i<32; i+=2)
        byte(row,n+i,kivi_code(load(row,n+i),p) | (kivi_code(load(row,n+i+1),p)<<4));
    }
  }
}
