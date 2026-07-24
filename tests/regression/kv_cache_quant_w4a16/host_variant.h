#ifndef _KV_CACHE_QUANT_W4A16_HOST_VARIANT_H_
#define _KV_CACHE_QUANT_W4A16_HOST_VARIANT_H_

#include <algorithm>
#include <cstdint>
#include <cstring>

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

static inline bool kv_cache_quant_is_pow2(uint32_t value) {
  return value != 0 && (value & (value - 1u)) == 0;
}

static inline uint32_t kv_cache_quant_log2(uint32_t value) {
  if (!kv_cache_quant_is_pow2(value)) {
    return UINT32_MAX;
  }
  uint32_t result = 0;
  while ((1u << result) < value) {
    ++result;
  }
  return result;
}

static inline uint32_t parse_kv_cache_quant_mode(const char* value) {
  if (0 == std::strcmp(value, "legacy_uint4_asymmetric")) {
    return KV_QUANT_LEGACY_UINT4_ASYMMETRIC;
  }
  if (0 == std::strcmp(value, "spinquant_signed_asymmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC;
  }
  if (0 == std::strcmp(value, "spinquant_signed_symmetric")) {
    return KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC;
  }
  return UINT32_MAX;
}

static inline const char* kv_cache_quant_mode_name(uint32_t mode) {
  switch (mode) {
  case KV_QUANT_LEGACY_UINT4_ASYMMETRIC:
    return "legacy_uint4_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC:
    return "spinquant_signed_asymmetric";
  case KV_QUANT_SPINQUANT_SIGNED_SYMMETRIC:
    return "spinquant_signed_symmetric";
  default:
    return "invalid";
  }
}

static inline uint32_t kv_cache_quant_mapping_mode(
    uint32_t work_items,
    uint32_t QDIR,
    uint32_t QBLK,
    uint64_t num_cores,
    uint64_t num_warps) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  // QDIR=0 still uses one cooperative warp per group. For QDIR=1, retain
  // warp reduction only when every group can be resident at once (generation).
  // Larger prefill workloads use one independent thread per source group.
  if (QDIR == 0 || !kv_cache_quant_is_pow2(QBLK) || (QBLK & 1u) != 0u) {
    return KV_CACHE_QUANT_MAPPING_WARP_GROUP;
  }
  const uint32_t resident_warps =
      std::max(1u, static_cast<uint32_t>(num_cores * num_warps));
  return work_items <= resident_warps
      ? KV_CACHE_QUANT_MAPPING_WARP_GROUP
      : KV_CACHE_QUANT_MAPPING_THREAD_GROUP;
#else
  (void)work_items;
  (void)QDIR;
  (void)QBLK;
  (void)num_cores;
  (void)num_warps;
  return KV_CACHE_QUANT_MAPPING_THREAD_GROUP;
#endif
}

static inline uint32_t kv_cache_quant_threads_per_block(
    uint32_t mapping_mode,
    uint64_t num_warps,
    uint64_t num_threads) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  if (mapping_mode == KV_CACHE_QUANT_MAPPING_WARP_GROUP) {
    return static_cast<uint32_t>(num_threads);
  }
  return std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
#else
  (void)mapping_mode;
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
    uint32_t mapping_mode,
    uint64_t num_cores,
    uint64_t num_warps) {
#if KV_CACHE_QUANT_VARIANT == KV_CACHE_QUANT_VARIANT_GROUPWISE
  if (mapping_mode == KV_CACHE_QUANT_MAPPING_WARP_GROUP) {
    return std::min(work_items,
                    std::max(1u, static_cast<uint32_t>(num_cores * num_warps)));
  }
  return std::min(
      (work_items + threads_per_block - 1u) / threads_per_block,
      std::max(1u, static_cast<uint32_t>(num_cores) * 4u));
#else
  (void)mapping_mode;
  (void)num_warps;
  return std::min((work_items + threads_per_block - 1u) / threads_per_block,
                  std::max(1u, static_cast<uint32_t>(num_cores) * 4u));
#endif
}

#endif
