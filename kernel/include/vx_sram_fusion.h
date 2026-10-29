#pragma once

#include <stdint.h>
#include <VX_config.h>

// C4 SRAM fusion ABI v2. The legacy GEMM descriptor remains 44 words.
namespace vortex {
namespace sram_fusion {

static constexpr uint32_t kCapability = 0x53465202u;
static constexpr uint64_t kBase = 0x1480ull;
static constexpr uint32_t kPollLimit = 100000000u;
static constexpr uint32_t kInputResident = 1u;
static constexpr uint32_t kOutputResident = 2u;
static constexpr uint32_t kOutputFp32 = 4u;

enum Register : uint32_t {
  kCaps = 0x00,
  kStatus = 0x04,
  kCommand = 0x08,
  kSequence = 0x0c,
  kTmemAddress = 0x10,
  kLmemAddress = 0x18,
  kLength = 0x20,
  kDoneSequence = 0x24,
  kError = 0x28,
  kPublish = 0x2c,
  kEntryBase = 0x100,
  kEntryStride = 0x10,
};

static inline uint32_t read32(uint32_t offset) {
  return *reinterpret_cast<volatile uint32_t*>(kBase + offset);
}

static inline void write32(uint32_t offset, uint32_t value) {
  *reinterpret_cast<volatile uint32_t*>(kBase + offset) = value;
}

static inline void write64(uint32_t offset, uint64_t value) {
  write32(offset, uint32_t(value));
  write32(offset + 4, uint32_t(value >> 32));
}

// Every producer warp calls this after its LMEM stores and before joining.
// The MMIO read is held until earlier accepted local stores physically commit.
static inline void publish() {
  __asm__ volatile("" ::: "memory");
  (void)read32(kPublish);
  __asm__ volatile("" ::: "memory");
}

static inline int arm(uint32_t entry, uint32_t generation, uint32_t flags) {
  const uint32_t base = kEntryBase + entry * kEntryStride;
  write32(base + 4, generation);
  write32(base, flags);
  // GEMM CONTROL uses a different buffered MMIO path. Complete a same-window
  // read before publishing that doorbell so it cannot overtake these stores.
  const uint32_t status = read32(base + 8);
  __asm__ volatile("" ::: "memory");
  if ((status & 8u) || read32(base + 4) != generation
      || ((status & 1u) != (flags != 0)))
    return -1;
  return 0;
}

static inline int wait_resident(uint32_t entry, uint32_t generation) {
  const uint32_t base = kEntryBase + entry * kEntryStride;
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    const uint32_t status = read32(base + 8);
    if ((status & 4u) && read32(base + 12) == generation)
      return (status & 8u) ? -int((status >> 16) ? status >> 16 : 1u) : 0;
  }
  return -100;
}

static inline int copy(bool to_tmem, uint64_t tmem_offset,
                       uint64_t lmem_address, uint32_t bytes,
                       uint32_t sequence) {
  if (read32(kStatus) & 1u)
    return -4;
  write64(kTmemAddress, tmem_offset);
  write64(kLmemAddress, lmem_address);
  write32(kLength, bytes);
  write32(kSequence, sequence);
  write32(kCommand, 1u | (to_tmem ? 2u : 0u));
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    const uint32_t error = read32(kError);
    if (error)
      return -int(error);
    const uint32_t status = read32(kStatus);
    if ((status & 3u) == 2u && read32(kDoneSequence) == sequence) {
      __asm__ volatile("" ::: "memory");
      return 0;
    }
  }
  return -100;
}

}  // namespace sram_fusion
}  // namespace vortex
