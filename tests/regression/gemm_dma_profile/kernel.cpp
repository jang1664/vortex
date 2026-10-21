#include "common.h"
#include <vx_intrinsics.h>

// Same 18-register descriptor ABI used by softmax's MMIO DMA helper and by
// VX_naive_external_dma_executor. Only source/destination strides differ.
static inline volatile uint32_t* dma_reg(uint32_t eid, uint32_t reg) {
  return reinterpret_cast<volatile uint32_t*>(uintptr_t(0x1480ull + 8 + eid * 72 + reg * 4));
}
static inline uint32_t mask(uint32_t bits) { return (1u << bits) - 1u; }

int main() {
  const auto* arg = reinterpret_cast<const kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  auto* results = reinterpret_cast<tile_result_t*>(arg->results);
  const uint64_t destination = uint64_t(LMEM_BASE_ADDR) + 65536;
  for (uint32_t sample = 0; sample < arg->tiles * arg->column_tiles * arg->repeats; ++sample) {
    const uint32_t tile = sample / arg->repeats;
    const uint64_t offset = uint64_t(tile % arg->tiles) * arg->rows * arg->stride
                          + uint64_t(tile / arg->tiles) * arg->row_bytes;
    const uint64_t source = arg->source + offset;
    uint64_t begin = csr_read(VX_CSR_MCYCLE);
    uint32_t alloc = 0;
    do {
      alloc = *reinterpret_cast<volatile uint32_t*>(uintptr_t(0x1480));
      if (csr_read(VX_CSR_MCYCLE) - begin > 1000000) {
        results[sample] = {0, 0, 0, 1};
        return 1;
      }
    } while (!(alloc & (1u << JOB_MMIO_ALLOC_SUCC_BIT)));
    uint32_t eid = (alloc >> JOB_MMIO_ALLOC_ENTRY_LSB) & mask(JOB_MMIO_ALLOC_ENTRY_BITS);
    uint32_t generation = (alloc >> JOB_MMIO_ALLOC_GEN_LSB) & mask(JOB_MMIO_ALLOC_GEN_BITS);
    const uint32_t regs[18] = {
      1, uint32_t(destination), uint32_t(destination >> 32),
      uint32_t(source), uint32_t(source >> 32),
      arg->stride, arg->row_bytes, 0, 0, 0, 0,
      arg->rows, 1, 1, arg->row_bytes, 0, 0, 0
    };
    for (uint32_t reg = 1; reg < 18; ++reg) *dma_reg(eid, reg) = regs[reg];
    *dma_reg(eid, 0) = 1;
    // Vortex FENCE flushes caches. Preserve the existing MMIO helper's ordering
    // without invalidating the source between repeated transfers.
    asm volatile ("" ::: "memory");
    uint64_t kicked = csr_read(VX_CSR_MCYCLE);
    for (;;) {
      uint32_t ctrl = *dma_reg(eid, 0);
      uint32_t current_gen = (ctrl >> JOB_MMIO_CTRL_GEN_LSB) & mask(JOB_MMIO_GEN_W);
      if (!(ctrl & (1u << JOB_MMIO_CTRL_VALID_BIT)) || current_gen != generation) break;
      if (csr_read(VX_CSR_MCYCLE) - kicked > 1000000) {
        results[sample] = {kicked - begin, csr_read(VX_CSR_MCYCLE) - kicked, 0, 2};
        return 1;
      }
    }
    asm volatile ("" ::: "memory");
    uint64_t finished = csr_read(VX_CSR_MCYCLE);
    // Verify every copied word outside the timed DMA interval.
    uint64_t errors = 0;
    const auto* copied = reinterpret_cast<volatile uint64_t*>(uintptr_t(destination));
    for (uint32_t row = 0; row < arg->rows; ++row) {
      for (uint32_t col = 0; col < arg->row_bytes / 8; ++col) {
        uint64_t word = (offset + uint64_t(row) * arg->stride) / 8 + col;
        if (copied[row * (arg->row_bytes / 8) + col] != profile_pattern(word)) ++errors;
      }
    }
    results[sample] = {kicked - begin, finished - kicked, errors, 0};
  }
  vx_fence();
  return 0;
}
