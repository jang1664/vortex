# Performance Monitor Timing Optimization Spec

## Status

Confirmed by the user on 2026-07-20.

## Goal

Insert one PERF-only pipeline boundary on each of the four selected performance-monitor update paths while preserving CSR addresses, interfaces, and exact counter values after drain.

## Scope

- `hw/rtl/core/VX_dma_unit_misal.sv`: stage only `dma_xfer_done` before `perf_xfers_r`.
- `hw/rtl/cache/VX_cache_wrap.sv`: stage only the L3 bypass read popcount.
- `hw/rtl/Vortex.sv`: stage only the global-memory read popcount used by `mem_perf.reads`.
- `hw/rtl/core/VX_core.sv`: stage the signed D-cache request/response delta before the pending-read accumulator.
- Focused PERF-enabled and PERF-disabled tests for drained-value correctness and unchanged non-selected counters.

## Design Decisions

1. Apply all four changes as one RTL batch.
2. Do not stage any other CPU-DMA, L3-write, global-memory-write, overlap, GEMM, local-DMA, HBM, or CSR path.
3. Keep global-memory pending/latency logic on the original raw request and response counts.
4. Shift the D-cache pending and latency recurrence together by staging the signed delta as a unit.
5. Preserve all software-visible widths, types, MPM classes, and CSR addresses.

## Verification Constraints

- Run RTL unit and xrt-vcs functional checks before synthesis.
- If pre-synthesis checks pass, run exactly one U55C synthesis and inspect the synthesized boundaries.
- Do not run placement, routing, implementation, or bitstream generation.
- Post-synthesis timing estimates are diagnostic only and do not prove 100 MHz closure.

## Final Agreed Spec

Confirmed. Implement the top-four batch exactly as described in `docs/plans/2026-07-20-002-perf-performance-monitor-timing-recovery-plan.md` and ignore all lower-ranked candidates.
