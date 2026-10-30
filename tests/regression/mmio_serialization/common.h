#pragma once
#include <stdint.h>
#include <VX_config.h>

static constexpr uint32_t kLanes = 16;
struct mmio_report_t {
  uint32_t allocation[kLanes];
  uint32_t unique[kLanes];
  uint32_t partial[kLanes];
  uint32_t shared[kLanes];
  uint32_t capability[kLanes];
  uint32_t published[kLanes];
  uint32_t control[kLanes];
};
struct kernel_arg_t {
  uint64_t output;
  uint64_t cycles;
};
