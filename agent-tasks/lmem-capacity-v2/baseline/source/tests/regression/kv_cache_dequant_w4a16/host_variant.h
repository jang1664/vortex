#ifndef _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_
#define _KV_CACHE_DEQUANT_W4A16_HOST_VARIANT_H_

#include "../kv_cache_common/kv_cache_w4a16.h"
#include <algorithm>
#include <cstdint>
#include <cstring>

#define KV_CACHE_DEQUANT_VARIANT_BASELINE 1
#define KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR 2
#define KV_CACHE_DEQUANT_VARIANT_GROUPWISE 3

#ifndef KV_CACHE_DEQUANT_VARIANT
#define KV_CACHE_DEQUANT_VARIANT KV_CACHE_DEQUANT_VARIANT_GROUPWISE
#endif

static inline const char* kv_cache_dequant_variant_name() {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_GROUPWISE
#if defined(KV_CACHE_DEQUANT_ARITH_FP16)
  return "groupwise_fp16";
#elif defined(KV_CACHE_DEQUANT_ARITH_FP32)
  return "groupwise_fp32";
#else
  return "groupwise";
#endif
#elif KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR
  return "packed_pair";
#else
  return "baseline";
#endif
}

static inline bool kv_cache_dequant_qblk_supported(uint32_t qblk) {
  return qblk == 32u || qblk == 64u || qblk == 128u;
}

static inline uint32_t kv_cache_dequant_threads_per_block(
    uint64_t num_warps,
    uint64_t num_threads) {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_GROUPWISE
  (void)num_warps;
  return static_cast<uint32_t>(num_threads);
#else
  return std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
#endif
}

static inline uint32_t kv_cache_dequant_work_items(uint32_t K,
                                                   uint32_t N,
                                                   uint32_t QBLK,
                                                   uint32_t QDIR,
                                                   uint32_t num_threads) {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_GROUPWISE
  if (QDIR == 0) {
    const uint32_t k_groups = (K + QBLK - 1u) / QBLK;
    const uint32_t pair_chunks =
        ((N >> 1) + num_threads - 1u) / num_threads;
    return k_groups * pair_chunks;
  }
  return K * ((N + QBLK - 1u) / QBLK);
#elif KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_PACKED_PAIR
  (void)QBLK;
  (void)QDIR;
  (void)num_threads;
  return K * (N >> 1);
#else
  (void)QBLK;
  (void)QDIR;
  (void)num_threads;
  return K * N;
#endif
}

static inline uint32_t kv_cache_dequant_blocks(uint32_t work_items,
                                               uint32_t threads_per_block,
                                               uint64_t num_cores,
                                               uint64_t num_warps) {
#if KV_CACHE_DEQUANT_VARIANT == KV_CACHE_DEQUANT_VARIANT_GROUPWISE
  (void)threads_per_block;
  return std::min(work_items,
                  std::max(1u, static_cast<uint32_t>(num_cores * num_warps)));
#else
  (void)num_warps;
  return std::min(
      (work_items + threads_per_block - 1u) / threads_per_block,
      std::max(1u, static_cast<uint32_t>(num_cores) * 4u));
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
