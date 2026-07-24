# KV-Cache Layout-Fused Decode Optimization Specification

Status: confirmed

## Goal

Explain why the C4 decode measurements for layout-fused KV Quant-K and
KV Quant-V are about eight times slower than their normal counterparts, then
optimize `tests/regression/kv_cache_quant_layout_fused_w4a16` for those decode
append-update cases.

## Scope

- `tests/regression/kv_cache_quant_layout_fused_w4a16/`
- Decode append-update cases from
  `docs/kernel/optimizations/c4_normal_vs_layout_fused_all_cases.md`
- Supporting benchmark/documentation changes required to select, measure, and
  explain the optimized kernel variant

RTL changes are out of scope unless software-kernel evidence proves an RTL
defect. Standalone KV quantization behavior must remain unchanged.

## Required Cases

1. KV Quant-K:
   `K=1, N=128, QBLK=128, source QDIR=1, GEMM QDIR=0,
   source-transposed, GEMM-A tiled, signed asymmetric, append at position 4095`
2. KV Quant-V:
   `K=1, N=128, QBLK=128, source QDIR=1, GEMM QDIR=1,
   GEMM-C tiled, signed symmetric, append at position 4095`
3. Representative prefill and edge cases sufficient to prove that the selected
   default does not regress correctness.

## Design Constraints

- Preserve the existing tile-major weight and qparam layouts.
- Preserve append semantics: only the requested cache position may change.
- Preserve optional logical correction qparam updates.
- Use the configured C4 hardware flow through `ci/run_black.sh hw`.
- Compare hardware cycles and instructions on identical shapes and binaries.
- Retain rejected variants when they are useful experimental evidence.

## Acceptance Criteria

- Both required decode cases pass host correctness verification.
- Both required decode cases materially reduce C4 fused cycles and dynamic
  instructions versus the current default measured in the referenced report.
- Relevant prefill/edge regression cases pass.
- The selected implementation is the Makefile default.
- The root cause, experiment results, and final measurements are recorded in
  the task status and optimization documentation.

## Confirmed Direction

First isolate code-size/inlining, launch, group-reduction, layout-address, and
store-layout costs. Prefer a dedicated append-update kernel path when evidence
shows that sharing the monolithic full-cache fused kernel is the dominant
fixed overhead.
