#pragma once
#include <stdint.h>
#include <VX_config.h>

struct tile_result_t {
  uint64_t setup_cycles, wait_cycles, errors, status;
};
struct kernel_arg_t {
  uint64_t source, results;
  uint32_t rows, row_bytes, stride, tiles, column_tiles, repeats;
};
static inline uint64_t profile_pattern(uint64_t word) {
  return 0x13579bdf2468ace0ull ^ (word * 0x100000001b3ull);
}
