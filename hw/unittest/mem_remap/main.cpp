// Copyright (c) 2026
//
// Licensed under the Apache License, Version 2.0.

#include "VVX_mem_remap.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

static bool trace_enabled = false;

bool sim_trace_enabled() {
  return trace_enabled;
}

void sim_trace_enable(bool enable) {
  trace_enabled = enable;
}

#define CHECK_EQ(actual, expected)                                             \
  do {                                                                         \
    auto actual_value = uint64_t(actual);                                      \
    auto expected_value = uint64_t(expected);                                  \
    if (actual_value == expected_value)                                        \
      break;                                                                   \
    std::cerr << "FAILED: " << #actual << " = 0x" << std::hex << actual_value \
              << ", expected 0x" << expected_value << std::dec << std::endl;  \
    std::abort();                                                              \
  } while (false)

namespace {

constexpr uint64_t kBlockSize = 64;
constexpr uint32_t kNumBanks = 32;
constexpr uint32_t kNumPorts = 8;
constexpr uint32_t kBanksPerPort = kNumBanks / kNumPorts;
constexpr uint32_t kPortBits = 3;
constexpr uint32_t kLocalBits = 2;
constexpr uint32_t kBankShift = 29;

[[maybe_unused]] uint64_t remap_expected(uint64_t addr) {
  uint64_t block = addr / kBlockSize;
  uint64_t byte_offset = addr & (kBlockSize - 1);
  uint64_t q = block >> kPortBits;
  uint64_t r = block & (kNumPorts - 1);
  uint64_t bank = (r << kLocalBits) | (q & (kBanksPerPort - 1));
  uint64_t offset = (q >> kLocalBits) * kBlockSize + byte_offset;
  return (bank << kBankShift) | offset;
}

uint64_t expected_address(uint64_t addr) {
#ifdef PLATFORM_MEMORY_REMAP
  return remap_expected(addr);
#else
  return addr;
#endif
}

} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  VVX_mem_remap dut;

  std::vector<uint64_t> addresses;
  for (uint64_t block = 0; block < 40; ++block) {
    addresses.push_back(block * kBlockSize);
    addresses.push_back(block * kBlockSize + 7);
    addresses.push_back(block * kBlockSize + 63);
  }
  addresses.push_back((uint64_t(1) << 20) + 13);
  addresses.push_back((uint64_t(1) << 32) + 255);

  for (auto addr : addresses) {
    dut.m_address = addr;
    dut.eval();
    CHECK_EQ(dut.hbm_address, expected_address(addr));
  }

#ifdef PLATFORM_MEMORY_REMAP
  const uint32_t expected_banks[16] = {
      0, 4, 8, 12, 16, 20, 24, 28,
      1, 5, 9, 13, 17, 21, 25, 29};
  for (uint32_t block = 0; block < 16; ++block) {
    uint64_t mapped = remap_expected(uint64_t(block) * kBlockSize);
    CHECK_EQ(mapped >> kBankShift, expected_banks[block]);
  }
  CHECK_EQ(remap_expected(32 * kBlockSize), 64);
  std::cout << "PASSED remap mode" << std::endl;
#else
  std::cout << "PASSED bypass mode" << std::endl;
#endif

  return 0;
}
