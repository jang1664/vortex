# PERF Timing Pipeline Spec

## Status

Confirmed by the user on 2026-07-13.

## Goal

Remove PERF-only timing pressure from the 8-channel HBM DMA aggregation, the
MPM CSR read mux, and the misaligned CPU DMA event-to-counter paths while
preserving all counter meanings and the existing CSR/runtime ABI.

## Scope

- `hw/rtl/mem/VX_dma_engine.sv`
- `hw/rtl/core/VX_csr_data.sv`
- `hw/rtl/core/VX_csr_unit.sv`
- `hw/rtl/core/VX_dma_unit_misal.sv`
- Focused PERF-enabled unit tests for DMA aggregation, CPU DMA counters, and
  CSR request/response alignment.

## Design Decisions

1. Keep every per-channel HBM `dma_perf_t` counter. The public HBM view remains
   aggregate counters plus `active_cycles` max/min; no per-channel CSR classes
   or runtime output are added.
2. Replace the procedural HBM sum chain with balanced reduction trees and
   register aggregate and max/min outputs. Keep aggregate `busy` combinational
   so overlap-counter edge semantics do not change.
3. Under `PERF_ENABLE`, decode one scalar candidate per MPM class, register the
   candidates together with the request selector and response metadata, then
   perform the final class selection in the following stage. Preserve one
   request per cycle under backpressure. PERF-disabled CSR behavior is unchanged.
4. Add the same one-cycle event-trigger stage used by the aligned DMA to the
   misaligned DMA. Keep `perf.busy` combinational and delay only counter updates.
5. Gate CSR write side effects and warp unlock with the accepted request
   handshake so the added pipeline cannot duplicate side effects.

## Constraints And Assumptions

- `PERF_CTR_BITS` remains 44.
- Existing MPM class values, CSR addresses, `dma_perf_t`, `hbm_dma_perf_t`, and
  runtime formatting remain unchanged.
- HBM aggregate/max/min and CPU DMA counters may be one cycle stale while work
  is active; after the pipeline drains, final totals must be bit-exact.
- The HBM latency view continues to use the existing active/stall/fire counters;
  no new latency accumulator is introduced.
- All added state is compiled only with `PERF_ENABLE`.

## Acceptance Criteria

- PERF-enabled DMA unit tests prove exact final totals with uneven channel work
  and injected backpressure.
- A focused CSR test proves back-to-back reads across classes 1 through 8 remain
  ordered and aligned under response backpressure.
- PERF-disabled unit builds still compile and pass.
- `fpint_gemm_ffn_hw` passes in xrt-vcs-sim with the requested config both
  without profiling and with PERF class 4.
- Post-route timing at the configured 100 MHz target has no failing path through
  the HBM reduction, CPU DMA counter enable, or combined address/class CSR mux.
