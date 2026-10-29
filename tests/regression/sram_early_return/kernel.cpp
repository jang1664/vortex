#include "common.h"
#include <vx_intrinsics.h>
#include <vx_sram_fusion.h>

#if !defined(GEMM_SRAM_FUSION) || !defined(LMEM_ENABLE)
#error "sram_early_return requires SRAM fusion and LMEM"
#endif

int main() {
  if (vx_core_id() != 0 || vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;
  vx_tmc_one();
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  namespace fusion = vortex::sram_fusion;
  arg->status = -1;
  if (fusion::read32(fusion::kCaps) != fusion::kCapability)
    return 0;

  if (arg->phase == 0u) {
    auto *source = reinterpret_cast<volatile uint64_t *>(kSource);
    for (uint32_t i = 0; i < kCopyWords; ++i)
      source[i] = pattern(i);
    fusion::publish();
    fusion::write64(fusion::kTmemAddress, 0u);
    fusion::write64(fusion::kLmemAddress, kSource);
    fusion::write32(fusion::kLength, kCopyBytes);
    fusion::write32(fusion::kSequence, kWriteSequence);
    fusion::write32(fusion::kCommand, 3u);
    // One same-window read orders the posted doorbell. This is deliberately
    // not a completion wait: return while the real long copy is still busy.
    const uint32_t status = fusion::read32(fusion::kStatus);
    arg->status = (status & 1u) ? 0 : -2;
    return 0;
  }

  if (arg->phase != 1u)
    return 0;
  const int result = fusion::copy(false, 0u, kDestination, kCopyBytes, kReadSequence);
  if (result) {
    arg->status = result;
    return 0;
  }
  auto *destination = reinterpret_cast<const volatile uint64_t *>(kDestination);
  auto *output = reinterpret_cast<volatile uint64_t *>(arg->output);
  for (uint32_t i = 0; i < kCopyWords; ++i)
    output[i] = destination[i];
  vx_fence();
  arg->status = 0;
  return 0;
}
