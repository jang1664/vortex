#pragma once

#include <stdint.h>

struct kernel_arg_t {
  uint64_t input_addr;
  uint64_t output_addr;
};

struct result_t {
  uint16_t h_add;
  uint16_t h_mul;
  uint32_t h_cmp;
  uint32_t s_add;
  uint32_t s_mul;
  uint32_t s_cmp;
};
