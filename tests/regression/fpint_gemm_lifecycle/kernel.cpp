// Keep the production descriptor allocation/program/wait implementation intact.
#define main production_kernel_main
#ifdef GEMM_NAIVE
#include "../fpint_gemm_ffn_hw_naive/kernel.cpp"
#else
#include "../fpint_gemm_ffn_hw/kernel.cpp"
#endif
#undef main
#include "common.h"

static uint64_t lifecycle_cycle() {
  static_assert(sizeof(uintptr_t) == 8, "Lifecycle cycle trace requires RV64");
  uint64_t value;
  __asm__ volatile("csrr %0, 0xb00" : "=r"(value) :: "memory");
  return value;
}

static float decode_half(uint16_t bits) {
  const uint32_t exponent = (bits >> 10) & 31u;
  const uint32_t fraction = bits & 1023u;
  if (exponent == 0) {
    const float value = float(fraction) * (1.0f / 16777216.0f);
    return (bits & 0x8000u) ? -value : value;
  }
  union { uint32_t bits; float value; } out;
  out.bits = ((uint32_t(bits) & 0x8000u) << 16)
           | ((exponent + 112u) << 23) | (fraction << 13);
  return out.value;
}

static bool within_tolerance(uint16_t actual, uint16_t expected) {
  if (actual == expected) return true;
  if ((actual & 0x7c00u) == 0x7c00u || (expected & 0x7c00u) == 0x7c00u)
    return false;
  const float a = decode_half(actual), e = decode_half(expected);
  float error = (e == 0.0f) ? a : (a - e) / e;
  if (error < 0.0f) error = -error;
  return error <= 0.001f;
}

int main() {
  if (vx_core_id() != 0 || vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;
  auto args = reinterpret_cast<lifecycle_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  auto offsets = reinterpret_cast<const volatile uint32_t*>(args->output_offsets);
  args->completed = 0;
  for (uint32_t job = 0; job < kLifecycleJobs; ++job) {
    auto arg = &args->jobs[job];
    const auto part = compute_partition(0, 1, arg->M, arg->N);
    // Volatile external-memory records remain inspectable without UART capture.
    auto trace = reinterpret_cast<volatile lifecycle_arg_t*>(args);
    trace->start_cycles[job] = lifecycle_cycle();
    if (!run_gemm_job_once(arg, part, true)) {
      args->failed_job = job;
      return 1;
    }
    vx_fence();
#ifdef GEMM_NAIVE
    const uint64_t output_base = arg->output_base;
#else
    const uint64_t output_base = arg->dram_out_base;
#endif
    auto expected = reinterpret_cast<const volatile uint16_t*>(args->references[job]);
    for (uint32_t i = 0; i < kLifecycleM * kLifecycleN; ++i) {
      auto ptr = reinterpret_cast<const volatile uint16_t*>(output_base + offsets[i]);
      const uint16_t actual = *ptr;
      const uint16_t reference = expected[i];
      if (!within_tolerance(actual, reference)) {
        args->failed_job = job;
        args->failed_index = i;
        args->actual_bits = actual;
        args->expected_bits = reference;
        return 1;
      }
    }
    trace->verified_cycles[job] = lifecycle_cycle();
    args->completed = job + 1;
    vx_fence();
  }
  return 0;
}
