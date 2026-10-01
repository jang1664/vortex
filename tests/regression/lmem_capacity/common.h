#pragma once
#include <stdint.h>
#include <VX_config.h>
static constexpr uint32_t kBankCount = LMEM_NUM_BANKS;
static constexpr uint32_t kWordBytes = XLEN / 8;
static constexpr uint32_t kSamples = 4 * kBankCount;
struct kernel_arg_t { uint64_t output; };
static inline uint64_t sample_offset(uint32_t i) {
  uint32_t bank = i % kBankCount;
  switch (i / kBankCount) {
  case 0: return bank * kWordBytes;
  case 1: return LMEM_SIZE - kBankCount * kWordBytes + bank * kWordBytes;
  case 2: return (1u << 20) - 2 * kBankCount * kWordBytes + bank * kWordBytes;
  default: return (LMEM_SIZE > (1u << 20) ? (1u << 20) : (1u << 19))
                    + bank * kWordBytes;
  }
}
static inline uint64_t sample_pattern(uint32_t i) {
  return 0x9b370000d4a50000ull ^ (uint64_t(i) * 0x100010001ull);
}
