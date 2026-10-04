#ifndef LMEM_REDUCTION_RAW_COMMON_H
#define LMEM_REDUCTION_RAW_COMMON_H

#include <stdint.h>

enum raw_mode_t {
  RAW_INT, RAW_FP32, RAW_FP16, RAW_WARP, RAW_LMEM_WARP, RAW_PEER, RAW_TREE,
  RAW_EXCHANGE
};

struct kernel_arg_t {
  uint32_t groups;
  uint32_t threads;
  uint32_t iterations;
  uint32_t mode;
  uint32_t active;
  uint32_t stride;
  uint32_t gap;
  uint32_t fence;
  uint32_t warps;
  uint64_t output_addr;
};

// active=0 cycles through causal-tail and full-warp masks.
static inline uint32_t active_lanes(uint32_t group, uint32_t threads,
                                    uint32_t active) {
  if (active) return active;
  const uint32_t counts[] = {1, threads > 1 ? 2u : 1u,
      threads > 2 ? 3u : threads, threads / 2 ? threads / 2 : 1u,
      threads > 1 ? threads - 1 : 1u, threads};
  return counts[group % 6];
}

#endif
