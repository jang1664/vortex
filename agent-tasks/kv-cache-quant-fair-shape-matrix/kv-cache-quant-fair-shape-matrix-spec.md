# Fair KV-Cache Quantization Shape-Matrix Specification

Status: confirmed

## Goal

Optimize and compare the normal and layout-fused KV-cache quantization
kernels across multiple decode and prefill shapes without deliberately
degrading either implementation. Both kernels must receive comparable
shape-aware optimization effort, preserve their intended output layouts, and
pass correctness checks before performance results are compared.

## Scope

- `tests/regression/kv_cache_quant_w4a16/`
- `tests/regression/kv_cache_quant_layout_fused_w4a16/`
- Host-side validation needed to reject unsupported append configurations
- A reproducible C4 result table and supporting optimization documentation

RTL changes are out of scope unless device-kernel evidence identifies an RTL
defect.

## Fairness Rules

1. Never slow down, de-optimize, or replace either kernel with a deliberately
   naive implementation to obtain a preferred ordering.
2. Apply the strongest safe optimization independently available to each
   kernel.
3. Give both kernels equivalent specialization opportunities for the same
   mathematical workload, especially one-token, one-quant-group decode.
4. Compare only correctness-passing configurations with identical source
   shape, quantization direction, quantization mode, and quantization block.
5. Report physical-output differences explicitly: normal writes standard
   packed row-major output, while layout-fused writes the final GEMM-consumer
   tiled layout.

## Design

### Decode

- Add a compact normal-kernel one-warp path for `K=1`, `QDIR=1`, and exactly
  one source quantization group.
- Retain the existing general normal groupwise paths for all other shapes.
- Use the compact layout-fused persistent path only for the same one-token,
  one-source-group condition.
- Reject unsupported layout-fused append configurations at the host boundary
  instead of silently producing incorrect multi-group results.
- Keep both compact paths runtime-`N` loops rather than hard-coding `N=128`.

### Prefill

- Preserve the existing optimized groupwise normal and optimized layout-fused
  prefill implementations.
- Do not route prefill through decode-specialized code.

## Shape Matrix

The final matrix must include:

- Decode single-group cases at `N=64`, `N=128`, and `N=256`.
- Both signed-asymmetric K-style and signed-symmetric V-style quantization.
- At least one non-default cache capacity or cache position.
- Prefill cases at more than one `K` and more than one `N`.
- Negative append validation for a multi-group shape.

The exact hardware subset may be reduced only when a tool or infrastructure
limit is recorded; correctness coverage must still include every category.

## Acceptance Criteria

- Normal and layout-fused decode specializations both pass correctness.
- Unsupported layout-fused append shapes fail with a clear host error.
- General normal and layout-fused prefill correctness remains passing.
- Static workload/variant tests pass.
- C4 cycles and instructions are collected under the same configuration for
  every reported pair.
- The final response contains one consolidated table covering all measured
  shapes, with fused/normal ratios and correctness status.
- No implementation is intentionally degraded to influence the comparison.
