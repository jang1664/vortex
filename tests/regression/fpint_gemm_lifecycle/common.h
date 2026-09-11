#ifndef FPINT_GEMM_LIFECYCLE_COMMON_H
#define FPINT_GEMM_LIFECYCLE_COMMON_H
#ifdef GEMM_NAIVE
#include "../fpint_gemm_ffn_hw_naive/common.h"
#else
#include "../fpint_gemm_ffn_hw/common.h"
#endif

static constexpr uint32_t kLifecycleJobs = 3;
static constexpr uint32_t kLifecycleM = 3;
static constexpr uint32_t kLifecycleK = 64;
static constexpr uint32_t kLifecycleN = 64;
struct lifecycle_arg_t {
  kernel_arg_t jobs[kLifecycleJobs];
  uint64_t references[kLifecycleJobs];
  uint64_t output_offsets;
  uint64_t start_cycles[kLifecycleJobs];
  uint64_t verified_cycles[kLifecycleJobs];
  uint32_t completed;
  uint32_t failed_job;
  uint32_t failed_index;
  uint32_t actual_bits;
  uint32_t expected_bits;
};
#endif
