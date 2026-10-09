#pragma once

#include "common.h"
#include <vx_spawn.h>

// Match the decoder connection kernels: scalar FP16 loads/stores, with
// contiguous source traversal for head-major conversion and V transpose.
inline void kernel_head_reorder(kernel_arg_t *__UNIFORM__ arg) {
  const auto* input = reinterpret_cast<const uint16_t*>(arg->input_addr);
  auto* output = reinterpret_cast<uint16_t*>(arg->output_addr);
  const uint32_t total = arg->batch * arg->seq * arg->heads * arg->headdim;
  const uint32_t stride = gridDim.x * blockDim.x;
  for (uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
       i < total; i += stride) {
    const uint32_t d = i % arg->headdim;
    uint32_t target;
    if (arg->kernel_id == KERNEL_HEAD_TRANSPOSE) {
      const uint32_t s = (i / arg->headdim) % arg->seq;
      const uint32_t matrix = i / (arg->seq * arg->headdim);
      target = (matrix * arg->headdim + d) * arg->seq + s;
    } else {
      const uint32_t h = (i / arg->headdim) % arg->heads;
      const uint32_t s = (i / (arg->headdim * arg->heads)) % arg->seq;
      const uint32_t b = i / (arg->seq * arg->heads * arg->headdim);
      target = ((b * arg->heads + h) * arg->seq + s) * arg->headdim + d;
    }
    output[target] = input[i];
  }
}
