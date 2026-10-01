#include <vx_intrinsics.h>
#include "common.h"
int main() {
  auto* arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  auto* output = reinterpret_cast<uint64_t*>(arg->output);
  // Startup runs a single lane. Direct accesses avoid scratch allocator and stack regions.
  for (uint32_t i = 0; i < kSamples; ++i) {
    auto* word = reinterpret_cast<volatile uint64_t*>(uintptr_t(LMEM_BASE_ADDR)
                                                       + sample_offset(i));
    *word = sample_pattern(i);
  }
  vx_fence();
  // Re-read after every write, exposing aliases between the lower/upper regions.
  for (uint32_t i = 0; i < kSamples; ++i) {
    auto* word = reinterpret_cast<volatile uint64_t*>(uintptr_t(LMEM_BASE_ADDR)
                                                       + sample_offset(i));
    auto* byte = reinterpret_cast<volatile uint8_t*>(word);
    byte[3] = 0x5a;
    vx_fence();
    output[i] = *word;
  }
  vx_fence();
  return 0;
}
