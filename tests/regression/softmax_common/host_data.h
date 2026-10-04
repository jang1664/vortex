#ifndef _SOFTMAX_HOST_DATA_H_
#define _SOFTMAX_HOST_DATA_H_

#include "../vector_common/fp16.h"
#include <cerrno>
#include <cstdlib>
#include <limits>
#include <random>
#include <vector>

// Keep the existing benchmark tensor identical to layout-fused bench_main.cpp.
static inline void initialize_softmax_scores(std::vector<fp16_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 22695477u + 1u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 64.0f);
  }
}

// Functionality tests select and print a fresh seed, or reuse a supplied seed.
static inline void initialize_softmax_scores(std::vector<fp16_t>& values,
                                             uint32_t seed) {
  std::mt19937 generator(seed);
  std::uniform_real_distribution<float> distribution(-2.0f, 2.0f);
  for (auto& value : values) {
    value = float_to_fp16(distribution(generator));
  }
}

static inline bool parse_softmax_seed(const char* text, uint32_t& seed) {
  if (!text || text[0] < '0' || text[0] > '9') return false;
  char* end = nullptr;
  errno = 0;
  const auto value = std::strtoull(text, &end, 10);
  if (errno || *end || value > std::numeric_limits<uint32_t>::max()) return false;
  seed = static_cast<uint32_t>(value);
  return true;
}

#endif  // _SOFTMAX_HOST_DATA_H_
