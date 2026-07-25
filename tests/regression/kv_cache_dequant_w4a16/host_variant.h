#ifndef _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_
#define _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_

#include "../kv_cache_common/kv_cache_w4a16.h"
#include <cstdint>
#include <cstring>

#define KV_CACHE_DEQUANT_VARIANT_BASELINE 1
#define KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR 2

#ifndef KV_CACHE_DEQUANT_VARIANT
#define KV_CACHE_DEQUANT_VARIANT KV_CACHE_DEQUANT_VARIANT_BASELINE
#endif

static inline const char* kv_cache_dequant_variant_name() {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR
  return "packed_pair";
#else
  return "baseline";
#endif
}

static inline uint32_t kv_cache_dequant_work_items(uint32_t K, uint32_t N) {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR
  return K * (N >> 1);
#else
  return K * N;
#endif
}

static inline uint32_t parse_kv_cache_dequant_mode(const char* value) {
  if (0 == std::strcmp(value, "legacy_uint4_asymmetric")) {
    return KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  }
  if (0 == std::strcmp(value, "signed_int4_asymmetric")
      || 0 == std::strcmp(value, "spinquant_signed_asymmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC;
  }
  if (0 == std::strcmp(value, "signed_int4_symmetric")
      || 0 == std::strcmp(value, "spinquant_signed_symmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC;
  }
  return UINT32_MAX;
}

static inline const char* kv_cache_dequant_mode_name(uint32_t mode) {
  switch (mode) {
  case KV_QUANT_LEGACY_UINT4_ASYMMETRIC:
    return "legacy_uint4_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC:
    return "signed_int4_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC:
    return "signed_int4_symmetric";
  default:
    return "invalid";
  }
}

#endif
