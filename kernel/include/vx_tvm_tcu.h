// Copyright © 2019-2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

#pragma once

#include <stdint.h>
#include <vx_tensor.h>

#define VX_TVM_TCU_ABI_VERSION 1

// TVM's first TCU lowering deliberately exposes a narrow, versioned kernel
// contract.  A single 32-thread Vortex workgroup computes one 16x16 output
// tile from row-major FP16 operands, accumulating in FP32 and storing FP16.
// Tail tiles and other TCU data modes remain on TVM's ordinary TIR lowering.
#if defined(EXT_TCU_ENABLE) && !defined(DISABLE_TCU_FP)
static inline int vx_tvm_tcu_fp16_tile(const void* a, const void* b, void* c,
                                      uint32_t m, uint32_t n, uint32_t k) {
  namespace vt = vortex::tensor;
  using context = vt::wmma_context<NUM_THREADS, vt::fp16, vt::fp16, vt::fp32>;

  if (context::tileM != 16 || context::tileN != 16 || context::tileK != 32 ||
      (m % context::tileM) != 0 || (n % context::tileN) != 0 ||
      (k % context::tileK) != 0) {
    return -1;
  }

  const auto* lhs = reinterpret_cast<const context::input_t*>(a);
  const auto* rhs = reinterpret_cast<const context::input_t*>(b);
  auto* out = reinterpret_cast<context::output_t*>(c);
  const uint32_t tile_row = blockIdx.y * context::tileM;
  const uint32_t tile_col = blockIdx.x * context::tileN;

  typename context::fragment_a lhs_fragment;
  typename context::fragment_b rhs_fragment;
  typename context::fragment_acc accumulator;
  context::fill_fragment(accumulator, 0.0f);

  for (uint32_t reduction = 0; reduction < k; reduction += context::tileK) {
    context::load_matrix_sync(lhs_fragment, lhs + tile_row * k + reduction, k);
    context::load_matrix_sync(rhs_fragment, rhs + reduction * n + tile_col, n);
    context::mma_sync(accumulator, lhs_fragment, rhs_fragment, accumulator);
  }

  context::store_matrix_sync(out + tile_row * n + tile_col, accumulator, n);
  return 0;
}
#endif
