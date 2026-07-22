#ifndef VORTEX_TESTS_REGRESSION_ADDRGEN_COMMON_H
#define VORTEX_TESTS_REGRESSION_ADDRGEN_COMMON_H

#include <stdint.h>

#define ADDRGEN_STREAM_COUNT 3

typedef struct {
  uint64_t base;
  int64_t stride[3];
  uint32_t bound[3];
  uint32_t reserved;
} addrgen_descriptor_t;

typedef struct {
  uint64_t descriptors_addr;
  uint64_t output_addr;
  uint32_t num_cases;
  uint32_t reserved;
} kernel_arg_t;

#endif
