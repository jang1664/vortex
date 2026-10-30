#include "common.h"
#include <vx_spawn.h>
#include <vx_sram_fusion.h>

#ifndef GEMM_SRAM_FUSION
#error "mmio_serialization requires unified C4 MMIO"
#endif

static void mmio_worker(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t lane = threadIdx.x;
  namespace mmio = vortex::sram_fusion;
  auto *report = reinterpret_cast<volatile mmio_report_t *>(arg->output);

  // One warp issues the same ALLOC read in all lanes. Exactly the available
  // entries must allocate; no SIMD lane may disappear from the response.
  report->allocation[lane] = mmio::read32(0);
  __syncthreads();

  // Each lane selects a different 64-bit register beat in entry zero.
  // CONTROL stays invalid throughout this test; no GEMM is launched.
  const uint32_t word = 2u + lane * 2u;
  mmio::entry_write(0, word, 0x12341000u + lane);
  report->unique[lane] = mmio::entry_read(0, word);
  auto *byte = reinterpret_cast<volatile uint8_t *>(mmio::entry_address(0, word) + 1u);
  *byte = 0xaau;
  report->partial[lane] = mmio::entry_read(0, word);
  __syncthreads();

  // The serializer services active lanes in ascending order. The last lane
  // therefore owns the final value when all lanes write one register.
  mmio::entry_write(0, 40u, 0xabc00000u + lane);
  report->shared[lane] = mmio::entry_read(0, 40u);
  report->capability[lane] = mmio::read32(mmio::kCaps);
  report->published[lane] = mmio::read32(mmio::kPublish);
  report->control[lane] = mmio::entry_read(lane % JOB_MMIO_NUM_ENTRIES, 0);
}

int main() {
  static_assert(NUM_THREADS == kLanes, "test requires one C4 16-lane warp");
  static_assert(JOB_MMIO_NUM_ENTRIES <= kLanes, "test must cover every descriptor slot");
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  const uint32_t grid = 1, block = kLanes;
  const uint64_t begin = csr_read(VX_CSR_MCYCLE);
  const int status = vx_spawn_threads(1, &grid, &block, (vx_kernel_func_cb)mmio_worker, arg);
  arg->cycles = csr_read(VX_CSR_MCYCLE) - begin;
  return status;
}
