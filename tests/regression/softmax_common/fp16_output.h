#ifndef _SOFTMAX_FP16_OUTPUT_H_
#define _SOFTMAX_FP16_OUTPUT_H_

#include "../vector_common/fp16.h"

// Keep the historical hardware FP16 conversion policy, including the archived
// Vivado IP's flush-to-zero behavior. Both layouts use this helper; do not
// repair subnormal probabilities in software.
static inline fp16_t softmax_probability_to_fp16(float value) {
  return float_to_fp16(value);
}

#endif
