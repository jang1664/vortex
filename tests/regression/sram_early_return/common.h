#pragma once

#include <stdint.h>
#include <VX_config.h>

static constexpr uint32_t kCopyBytes = 65536u;
static constexpr uint32_t kCopyWords = kCopyBytes / sizeof(uint64_t);
static constexpr uint32_t kWriteSequence = 0xe001u;
static constexpr uint32_t kReadSequence = 0xe002u;
static constexpr uint64_t kSource = uint64_t(LMEM_BASE_ADDR) + 0x20000u;
static constexpr uint64_t kDestination = uint64_t(LMEM_BASE_ADDR) + 0x40000u;

struct kernel_arg_t {
  uint64_t output;
  uint32_t phase;
  int32_t status;
};

static inline uint64_t pattern(uint32_t index) {
  return (uint64_t(index ^ 0xa531c49bu) << 32)
       | uint64_t(index * 2654435761u + 0x79e26d13u);
}
