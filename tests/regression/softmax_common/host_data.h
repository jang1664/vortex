#ifndef _SOFTMAX_HOST_DATA_H_
#define _SOFTMAX_HOST_DATA_H_

#include "../vector_common/fp16.h"
#include <vector>

// Keep baseline and layout-fused benchmarks on the exact same score tensor.
static inline void initialize_softmax_scores(std::vector<fp16_t>& values) {
  for (size_t i = 0; i < values.size(); ++i) {
    int x = int((i * 22695477u + 1u) & 0xffu) - 128;
    values[i] = float_to_fp16(float(x) / 64.0f);
  }
}

#endif  // _SOFTMAX_HOST_DATA_H_
