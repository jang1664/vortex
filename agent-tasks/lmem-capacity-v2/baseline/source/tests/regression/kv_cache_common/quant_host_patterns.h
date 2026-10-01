#ifndef _QUANT_HOST_PATTERNS_H_
#define _QUANT_HOST_PATTERNS_H_

#include "kv_cache_w4a16.h"
#include <cstring>
#include <vector>

// Optional CPU-reference test inputs. An empty pattern retains the historical
// deterministic workload; these patterns do not affect benchmark payloads.
static inline bool set_quant_test_pattern(std::vector<fp16_t>& values,
                                         const char* pattern) {
  if (!pattern || !*pattern) return true;
  const fp16_t tiny[] = {0x0000, 0x0001, 0x0002, 0x01ff, 0x03ff,
                         0x8001, 0x8002, 0x81ff, 0x83ff};
  const fp16_t large[] = {0x7bff, 0xfbff, 0x0000, 0x3c00, 0xbc00};
  for (size_t i = 0; i < values.size(); ++i) {
    if (0 == std::strcmp(pattern, "zeros")) values[i] = 0;
    else if (0 == std::strcmp(pattern, "constant")) values[i] = float_to_fp16(-0.5f);
    else if (0 == std::strcmp(pattern, "ties")) values[i] = float_to_fp16(float(int(i % 17) - 8) / 8.0f);
    else if (0 == std::strcmp(pattern, "tiny")) values[i] = tiny[i % (sizeof(tiny) / sizeof(tiny[0]))];
    else if (0 == std::strcmp(pattern, "large")) values[i] = large[i % (sizeof(large) / sizeof(large[0]))];
    else return false;
  }
  return true;
}

#endif
