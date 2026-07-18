# LMEM DMA Common-Core Performance Cause Analysis

Created: 2026-07-18
Status: complete

## Objective

Explain the measured common-core wrapper regression with controlled simulation
data before changing production RTL:

- generation: 14,201 -> 14,434 cycles (+233, +1.64%);
- prefill: 194,214 -> 211,671 cycles (+17,457, +8.99%).

The older 14,194/199,796 baseline was taken at a different source-tree point
and is historical only.

Resource utilization is out of scope. Functional output must remain bit-exact.

## Fixed Comparison Contract

- Baseline: the dedicated `VX_lmem_dma_misal` implementation at repository
  `HEAD`, before the uncommitted common-core wrapper refactor.
- Candidate: the current common-core wrapper worktree.
- Simulator: configured-build VCS for directed unit measurements and
  `xrt-vcs-sim` for full-workload validation.
- Clock: 10 ns; all latency results are reported in cycles.
- Bus model, request backpressure, response ordering, command descriptors, and
  compile-time configuration must be identical within each A/B comparison.
- A comparison is invalid if either side fails data checking or uses a stale
  simulator binary/waveform.

## Hypotheses and Required Measurements

### H1: Fixed command prologue/epilogue

Measure command acceptance to first source request, last destination request to
copy completion, and copy completion through GEMM sync to external `done`.
Use zero-byte, one-beat, and long-transfer commands to separate fixed cost from
throughput cost.

### H2: Steady-state destination bubbles

Measure source-request fire, source-response fire, destination-write fire, and
their valid-without-ready stalls. For a contiguous aligned transfer, report
destination-write inter-fire gaps and sustained bytes/cycle. The legacy design
previously demonstrated one destination beat per cycle after fill; the common
core must be checked against that result under the same testbench conditions.

### H3: Per-segment address-generation cost

Compare equal total bytes as one long segment versus many one-beat segments.
The delta after subtracting fixed command cost estimates the added cost per
segment. This also tests whether removing explicit `RD_PREFETCH_DEPTH` affects
segment-boundary overlap even with eight outstanding beat slots.

### H4: Misaligned pack/reorder-slot drain cost

Compare aligned and independently misaligned source/destination offsets, and
record slot occupancy plus pack/write activity where visible. Separate pack
pipeline bubbles from external ready/valid backpressure.

### H5: Full-workload amplification and overlap

Count commands by LDMA stream and direction in generation and prefill. Use the
directed-test fixed/per-segment costs to predict total added cycles, then compare
the prediction with +240 and +12,127 cycles. Residual time is attributed only
after checking concurrency, GEMM sync wait, and LMEM/GEMM arbitration stalls.

## Directed Matrix

At minimum, run both directions for:

1. zero-byte no-op;
2. one aligned 16-byte segment;
3. one aligned 128-byte segment;
4. eight aligned 16-byte segments;
5. 512 aligned 16-byte segments;
6. equal-byte single-segment versus multi-segment pairs;
7. representative source/destination misalignment;
8. deterministic source and destination backpressure.

## Decision Rule

A cause is considered confirmed when a controlled A/B changes only that factor,
the delta is repeatable, and its event/state counters account for the observed
cycle difference. RTL structure alone is supporting evidence, not confirmation.

The final report must rank causes by explained cycles for generation and
prefill and identify the smallest production optimizations worth trying next.

## Conclusion

- H1 confirmed: command spacing increases by four fixed cycles, decomposed as
  request enqueue +1, response/pack/write buffering +2, and wrapper rearm +1.
- H2 rejected for an isolated DMA: transfer-length and alternating-backpressure
  A/B tests preserve the same fixed four-cycle delta through 512 segments.
- H3 rejected for the tested aligned path: outstanding eight matches legacy
  prefetch depth four within the fixed command cost.
- H5 confirmed: prefill amplifies the fixed latency through shared-LMEM phase
  changes. Input command latency rises by 12,296 cycles, equal to GEMM-busy
  growth, while two weight-notification states explain 15,501 cycles and 90.42%
  of the GEMM FSM increase.
- H4 was functionally covered but is not the dominant aligned generation or
  prefill cause established by the focused full-workload trace.
