# Naive GEMM Sync Balanced Reduction Spec

## Goal

Remove the 100 MHz critical path caused by the sequential dynamic-index update
fold in `VX_gemm_sync_naive` by adopting the balanced per-register reduction
used by `VX_gemm_sync`.

## Scope

- Modify `hw/rtl/core/gemm/VX_gemm_sync_naive.sv`.
- Add or extend focused RTL verification only as needed.
- Do not change the GEMM command interfaces, opcodes, or notification protocol.

## Design Decisions

- Compute update hits independently for every fixed sync-register index.
- Preserve deterministic node0-to-node4 update semantics:
  - the last SET wins;
  - ADDs before the last SET are discarded;
  - ADDs after the last SET are accumulated;
  - when no SET is present, all ADDs accumulate onto the current value.
- Use a balanced 32-bit adder reduction rather than sequential dynamic writes.
- Retain reset and `gemm_start_i` as higher-priority register clears.
- Retain `NUM_SYNC_REGS=9` and all naive-specific interfaces and opcodes.

## Constraints And Assumptions

- Arithmetic remains modulo 2^32.
- Out-of-range register IDs are ignored.
- Same-cycle updates to different registers remain independent.
- The update remains single-cycle; no protocol-visible latency is added.

## Final Agreed Spec

Confirmed by the user on 2026-07-14: apply the improve sync balanced-update
approach to the naive RTL after reviewing the timing and semantic equivalence.
