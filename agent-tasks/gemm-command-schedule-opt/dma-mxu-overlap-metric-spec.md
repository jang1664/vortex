# DMA+MXU Overlap Metric Specification

## Goal

Report how much ancillary DMA work is hidden by the primary MXU compute work.

## Scope

- Count the union of CPU DMA, aggregate HBM DMA, and the four LMEM DMA `busy`
  signals once per cycle.
- Expose that union count as an MXU performance counter.
- Change the runtime `DMA+MXU overlap` percentage denominator from GEMM total
  cycles to DMA union-active cycles.
- Preserve the existing overlap numerator: DMA union-active and MXU computing
  in the same cycle.
- Verify the counter path and rerun the existing WLOAD8 `fpint_gemm_ffn_hw`
  workload with `xrt-vcs-sim` performance class 3.

## Design Decisions

- Do not sum individual DMA `active_cycles`; concurrent DMA engines would be
  double-counted.
- Reuse the existing `any_dma_busy` predicate for both the new denominator and
  the existing overlap numerator so the sets are definitionally aligned.
- Add a dedicated 64-bit MPM counter in the ACCEL_MXU class.
- Print both raw counts as `overlap / dma_active`, with a zero-denominator guard.

## Constraints and Assumptions

- `PERF_CTR_BITS` remains the counter width used by all accelerator counters.
- Per-core counters are summed by the runtime, as with the existing overlap
  counter.
- No scheduler, DMA datapath, or MXU behavior changes are in scope.

## Final Agreed Specification

**Confirmed 2026-08-06.**

```text
DMA+MXU overlap (%) =
    100 * cycles(any_dma_busy && mxu_computing)
        / cycles(any_dma_busy)
```
