#ifndef _KV_CACHE_QUANT_W4A16_HOST_VARIANT_H_
#define _KV_CACHE_QUANT_W4A16_HOST_VARIANT_H_

#include <algorithm>
#include <cstdint>

#define KV_CACHE_QUANT_VARIANT_BASELINE 1
#define KV_CACHE_QUANT_VARIANT_GROUPWISE 2

#ifndef KV_CACHE_QUANT_VARIANT
#define KV_CACHE_QUANT_VARIANT KV_CACHE_QUANT_VARIANT_BASELINE
#endif

static inline const char* kv_cache_quant_variant_name() {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  return "groupwise";
#else
  return "baseline";
#endif
}

static inline uint32_t kv_cache_quant_threads_per_block(
    uint64_t num_warps,
    uint64_t num_threads) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  (void)num_warps;
  return static_cast<uint32_t>(num_threads);
#else
  return std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
#endif
}

static inline uint32_t kv_cache_quant_work_items(
    uint32_t K,
    uint32_t N,
    uint32_t QBLK,
    uint32_t QDIR) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  if (QDIR == 0) {
    return ((K + QBLK - 1u) / QBLK) * (N >> 1);
  }
  if ((QBLK & 1u) == 0u) {
    return K * ((N + QBLK - 1u) / QBLK);
  }
#endif
  return K * (N >> 1);
}

static inline uint32_t kv_cache_quant_blocks(
    uint32_t work_items,
    uint32_t threads_per_block,
    uint64_t num_cores,
    uint64_t num_warps) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  (void)threads_per_block;
  return std::min(work_items,
                  std::max(1u, static_cast<uint32_t>(num_cores * num_warps)));
#else
  (void)num_warps;
  return std::min((work_items + threads_per_block - 1u) / threads_per_block,
                  std::max(1u, static_cast<uint32_t>(num_cores) * 4u));
#endif
}

#endif
