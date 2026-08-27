// Copyright © 2019-2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

#pragma once

#include <stdint.h>
#include <VX_config.h>

#define VX_TVM_GEMM_ABI_VERSION 1
#define VX_TVM_GEMM_MODE_NAIVE 1
#define VX_TVM_GEMM_MODE_IMPROVE 2

#ifdef ENABLE_GEMM_ACCEL
namespace vortex {
namespace tvm_gemm {

static constexpr uint64_t kRegisterBase = 0x1080ull;
static constexpr uint32_t kBeatBytes = 8;
static constexpr uint32_t kWordsPerBeat = kBeatBytes / 4;
static constexpr uint32_t kRegisterCount = 44;
static constexpr uint32_t kEntryCount = 4;
static constexpr uint32_t kEntryStride =
    ((kRegisterCount + kWordsPerBeat - 1) / kWordsPerBeat) * kBeatBytes;

enum Register : uint32_t {
  kControl = 0,
  kInputBase = 1,
  kWeightBase = 3,
  kOutputBase = 5,
  kScaleBase = 7,
  kZeroPointBase = 9,
  kInputScratch0 = 11,
  kInputScratch1 = 13,
  kWeightScratch0 = 15,
  kWeightScratch1 = 17,
  kScaleScratch0 = 19,
  kScaleScratch1 = 21,
  kZeroPointScratch0 = 23,
  kZeroPointScratch1 = 25,
  kOutputScratch0 = 27,
  kM = 29,
  kN = 30,
  kK = 31,
  kLog2QBlock = 32,
  kTargetM = 33,
  kTargetN = 34,
  kTargetK = 35,
  kMStart = 36,
  kNStart = 37,
  kWeightTranspose = 38,
  kQuantDirection = 39,
  kModeRegister40 = 40,
  kModeRegister41 = 41,
  kModeRegister42 = 42,
};

static inline uint32_t mask(uint32_t bits) {
  return bits >= 32 ? 0xffffffffu : ((1u << bits) - 1u);
}

static inline uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

static inline uint32_t log2_pow2(uint32_t value) {
  uint32_t result = 0;
  while ((1u << result) != value) ++result;
  return result;
}

static inline volatile uint32_t* register_address(uint32_t entry, uint32_t index) {
  const uint32_t beat = index / kWordsPerBeat;
  const uint32_t word = index % kWordsPerBeat;
  return reinterpret_cast<volatile uint32_t*>(
      kRegisterBase + kBeatBytes + uint64_t(entry) * kEntryStride +
      uint64_t(beat) * kBeatBytes + uint64_t(word) * 4);
}

static inline void write32(uint32_t entry, uint32_t index, uint32_t value) {
  *register_address(entry, index) = value;
}

static inline uint32_t read32(uint32_t entry, uint32_t index) {
  return *register_address(entry, index);
}

static inline void write64(uint32_t entry, uint32_t index, uint64_t value) {
  write32(entry, index, uint32_t(value));
  write32(entry, index + 1, uint32_t(value >> 32));
}

struct Scratch {
  uint64_t input[2];
  uint64_t weight[2];
  uint64_t scale[2];
  uint64_t zero_point[2];
  uint64_t output[2];
  uint64_t partial_sum;
};

static inline bool allocate_scratch(Scratch* scratch, uint32_t qblock,
                                    uint32_t quant_direction, uint32_t mode) {
  constexpr uint64_t tile_m = 128;
  constexpr uint64_t tile_n = 128;
  constexpr uint64_t tile_k = 128;
  const uint64_t groups_k = (tile_k + qblock - 1) / qblock;
  const uint64_t groups_n = (tile_n + qblock - 1) / qblock;
  const uint64_t input_bytes = tile_m * tile_k * 2;
  const uint64_t weight_bytes = tile_k * ((tile_n + 1) / 2);
  const uint64_t qparam_bytes =
      quant_direction == 0 ? groups_k * tile_n * 2 : tile_k * groups_n * 2;
  const uint64_t output_bytes = tile_m * tile_n * 2;
  const uint64_t partial_sum_bytes = tile_m * tile_n * 4;
  const uint64_t local_memory_base = uint64_t(LMEM_BASE_ADDR);
  uint64_t cursor = mode == VX_TVM_GEMM_MODE_NAIVE ? local_memory_base : 0;
  const uint64_t limit = mode == VX_TVM_GEMM_MODE_NAIVE
                             ? local_memory_base + (uint64_t(1) << LMEM_LOG_SIZE)
                             : uint64_t(TMEM_BANK_SIZE) * 32;

  auto allocate = [&](uint64_t bytes, uint64_t* address) {
    cursor = align_up(cursor, 64);
    if (cursor > limit || bytes > limit - cursor) return false;
    *address = cursor;
    cursor += align_up(bytes, 64);
    return true;
  };
  if (!allocate(input_bytes, &scratch->input[0]) ||
      !allocate(input_bytes, &scratch->input[1]) ||
      !allocate(weight_bytes, &scratch->weight[0]) ||
      !allocate(weight_bytes, &scratch->weight[1]) ||
      !allocate(qparam_bytes, &scratch->scale[0]) ||
      !allocate(qparam_bytes, &scratch->scale[1]) ||
      !allocate(qparam_bytes, &scratch->zero_point[0]) ||
      !allocate(qparam_bytes, &scratch->zero_point[1]) ||
      !allocate(output_bytes, &scratch->output[0])) {
    return false;
  }
  if (mode == VX_TVM_GEMM_MODE_IMPROVE) {
    return allocate(output_bytes, &scratch->output[1]);
  }
  scratch->output[1] = 0;
  return allocate(partial_sum_bytes, &scratch->partial_sum);
}

static inline int submit(const void* input, const void* weight, const void* scale,
                         const void* zero_point, void* output, uint32_t m, uint32_t n,
                         uint32_t k, uint32_t qblock, uint32_t weight_transpose,
                         uint32_t quant_direction, uint32_t mode) {
#if defined(GEMM_NAIVE)
  if (mode != VX_TVM_GEMM_MODE_NAIVE) return -2;
#elif defined(GEMM_IMPROVE)
  if (mode != VX_TVM_GEMM_MODE_IMPROVE) return -2;
#else
  if (mode == VX_TVM_GEMM_MODE_NAIVE) return -2;
#endif
  if (m == 0 || n == 0 || k == 0 || qblock == 0 ||
      (qblock & (qblock - 1)) != 0 || weight_transpose > 1 ||
      quant_direction > 1 || (quant_direction == 0 && (128 % qblock) != 0)) {
    return -3;
  }

  Scratch scratch = {};
  if (!allocate_scratch(&scratch, qblock, quant_direction, mode)) return -4;
  const uint32_t allocation = *reinterpret_cast<volatile uint32_t*>(kRegisterBase);
  if (((allocation >> JOB_MMIO_ALLOC_SUCC_BIT) & 1u) == 0) return -5;
  const uint32_t entry =
      (allocation >> JOB_MMIO_ALLOC_ENTRY_LSB) & mask(JOB_MMIO_ALLOC_ENTRY_BITS);
  const uint32_t generation =
      (allocation >> JOB_MMIO_ALLOC_GEN_LSB) & mask(JOB_MMIO_ALLOC_GEN_BITS);
  if (entry >= kEntryCount) return -6;

  write64(entry, kInputBase, reinterpret_cast<uint64_t>(input));
  write64(entry, kWeightBase, reinterpret_cast<uint64_t>(weight));
  write64(entry, kOutputBase, reinterpret_cast<uint64_t>(output));
  write64(entry, kScaleBase, reinterpret_cast<uint64_t>(scale));
  write64(entry, kZeroPointBase, reinterpret_cast<uint64_t>(zero_point));
  write64(entry, kInputScratch0, scratch.input[0]);
  write64(entry, kInputScratch1, scratch.input[1]);
  write64(entry, kWeightScratch0, scratch.weight[0]);
  write64(entry, kWeightScratch1, scratch.weight[1]);
  write64(entry, kScaleScratch0, scratch.scale[0]);
  write64(entry, kScaleScratch1, scratch.scale[1]);
  write64(entry, kZeroPointScratch0, scratch.zero_point[0]);
  write64(entry, kZeroPointScratch1, scratch.zero_point[1]);
  write64(entry, kOutputScratch0, scratch.output[0]);
  write32(entry, kM, m);
  write32(entry, kN, n);
  write32(entry, kK, k);
  write32(entry, kLog2QBlock, log2_pow2(qblock));
  write32(entry, kTargetM, m);
  write32(entry, kTargetN, n);
  write32(entry, kTargetK, k);
  write32(entry, kMStart, 0);
  write32(entry, kNStart, 0);
  write32(entry, kWeightTranspose, weight_transpose);
  write32(entry, kQuantDirection, quant_direction);
  if (mode == VX_TVM_GEMM_MODE_NAIVE) {
    write64(entry, kModeRegister40, scratch.partial_sum);
  } else {
    write32(entry, kModeRegister40, 7);
    write32(entry, kModeRegister41, 7);
    write32(entry, kModeRegister42, 7);
  }
  write32(entry, kControl, 1);

  for (;;) {
    const uint32_t control = read32(entry, kControl);
    const uint32_t current_generation =
        (control >> JOB_MMIO_CTRL_GEN_LSB) & mask(JOB_MMIO_GEN_W);
    const uint32_t valid = (control >> JOB_MMIO_CTRL_VALID_BIT) & 1u;
    if (generation < current_generation || valid == 0) break;
  }
  return 0;
}

}  // namespace tvm_gemm
}  // namespace vortex

static inline int vx_tvm_gemm_w4a16(
    const void* input, const void* weight, const void* scale, const void* zero_point,
    void* output, uint32_t m, uint32_t n, uint32_t k, uint32_t qblock,
    uint32_t weight_transpose, uint32_t quant_direction, uint32_t mode) {
  return vortex::tvm_gemm::submit(input, weight, scale, zero_point, output, m, n, k,
                                 qblock, weight_transpose, quant_direction, mode);
}
#endif
