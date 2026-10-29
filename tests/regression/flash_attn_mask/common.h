#pragma once

#include "../flash_attn/common.h"
#include "../vector_common/fp16.h"

#define MASK_MAX_ROWS 4u
#define MASK_PAD_ROWS 8u
#define MASK_WIDTH 128u
#define MASK_REPORT_MAGIC 0x4d41534bu

// Test-only HBM snapshots, addressed by the existing debug_score_base field.
// The production attention argument ABI and mask validation are unchanged.
struct mask_snapshot_t {
  float row_max[MASK_MAX_ROWS];
  float row_sum[MASK_MAX_ROWS];
  float row_alpha[MASK_MAX_ROWS];
  float accumulator[MASK_MAX_ROWS * MASK_WIDTH];
  fp16_t probabilities[MASK_PAD_ROWS * MASK_WIDTH];
  fp16_t output[MASK_MAX_ROWS * MASK_WIDTH];
};

struct mask_report_t {
  uint32_t magic;
  uint32_t completed_phases;
  mask_snapshot_t phases[2];
};
