#ifndef _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_
#define _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_

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

#endif
