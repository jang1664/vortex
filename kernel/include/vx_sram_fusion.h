#pragma once

#include <stdint.h>
#include <VX_config.h>

// C4 SRAM operations share the ordinary GEMM descriptor/MMIO path (ABI v3).
namespace vortex {
namespace sram_fusion {

static constexpr uint32_t kCapability = 0x53465203u;
static constexpr uint64_t kBase = 0x1080ull;
static constexpr uint32_t kPollLimit = 100000000u;
static constexpr uint32_t kIoControl = 44u;
static constexpr uint32_t kIoError = 45u;
static constexpr uint32_t kPublish = 0x3f0u;
static constexpr uint32_t kCaps = 0x3f8u;
static constexpr uint32_t kHbm = 0u, kTmem = 1u, kLmem = 2u;
static constexpr uint32_t kOutputFp32 = 1u << 4;

static inline uint32_t read32(uint32_t offset) {
  return *reinterpret_cast<volatile uint32_t*>(kBase + offset);
}
static inline uint64_t entry_address(uint32_t entry, uint32_t word) {
  return kBase + 8u + uint64_t(entry) * GEMM_CFG_REG_NUM * 4u + word * 4u;
}
static inline uint32_t entry_read(uint32_t entry, uint32_t word) {
  return *reinterpret_cast<volatile uint32_t*>(entry_address(entry, word));
}
static inline void entry_write(uint32_t entry, uint32_t word, uint32_t value) {
  *reinterpret_cast<volatile uint32_t*>(entry_address(entry, word)) = value;
}
static inline void entry_write64(uint32_t entry, uint32_t word, uint64_t value) {
  entry_write(entry, word, uint32_t(value));
  entry_write(entry, word + 1u, uint32_t(value >> 32));
}

// Each producing warp orders its stores through the same GEMM MMIO stream.
static inline void publish() {
  __asm__ volatile("" ::: "memory");
  (void)read32(kPublish);
  __asm__ volatile("" ::: "memory");
}

static inline int allocate(uint32_t &entry, uint32_t &generation) {
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    const uint32_t result = read32(0);
    if (!(result & (1u << JOB_MMIO_ALLOC_SUCC_BIT)))
      continue;
    entry = (result >> JOB_MMIO_ALLOC_ENTRY_LSB)
        & ((1u << JOB_MMIO_ALLOC_ENTRY_BITS) - 1u);
    generation = (result >> JOB_MMIO_ALLOC_GEN_LSB)
        & ((1u << JOB_MMIO_ALLOC_GEN_BITS) - 1u);
    return entry < JOB_MMIO_NUM_ENTRIES ? 0 : -6;
  }
  return -100;
}

static inline int wait_resident(uint32_t entry, uint32_t generation) {
  for (uint32_t poll = 0; poll < kPollLimit; ++poll) {
    const uint32_t control = entry_read(entry, 0);
    if (((control >> JOB_MMIO_CTRL_GEN_LSB) & ((1u << JOB_MMIO_GEN_W) - 1u)) != generation)
      return -6;
    if (!(control & ((1u << JOB_MMIO_CTRL_OCCUPY_BIT) | (1u << JOB_MMIO_CTRL_WORKING_BIT)))) {
      const uint32_t error = entry_read(entry, kIoError);
      return error ? -int(error) : 0;
    }
  }
  return -100;
}

// Copy-only descriptors initialize scratch or run memory tests. Attention's
// per-GEMM transfers are integrated, with lengths derived by RTL from GEMM shape.
static inline int submit_copy(bool to_tmem, uint64_t tmem_offset,
                              uint64_t lmem_address, uint32_t bytes,
                              uint32_t &entry, uint32_t &generation) {
  const int result = allocate(entry, generation);
  if (result) return result;
  entry_write64(entry, to_tmem ? 1u : 5u, lmem_address);
  entry_write64(entry, to_tmem ? 11u : 27u, tmem_offset);
  entry_write(entry, 29u, bytes);
  entry_write(entry, kIoControl, (to_tmem ? 1u : 2u) << 5);
  entry_write(entry, 0u, 1u);
  // Orders the posted start without waiting for the copy to complete.
  (void)entry_read(entry, 0u);
  return 0;
}

static inline int copy(bool to_tmem, uint64_t tmem_offset,
                       uint64_t lmem_address, uint32_t bytes) {
  uint32_t entry, generation;
  const int result = submit_copy(to_tmem, tmem_offset, lmem_address,
                                 bytes, entry, generation);
  return result ? result : wait_resident(entry, generation);
}

} // namespace sram_fusion
} // namespace vortex
