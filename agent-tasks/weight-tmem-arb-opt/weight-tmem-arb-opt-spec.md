# Weight TMEM Arbitration Optimization Specification

Status: confirmed

## Goal

Reduce the Weight-response and four-beat Input-burst gaps caused by contention
between Input and Weight reads on the eight single-port TMEM banks. Preserve
correctness, exact W/S/Z generations, command ordering, and bounded fairness.

The authoritative design and verification plan is:

`docs/future_optim/gemv/gemm_improve/weight_tmem_arb_opt.md`

## Confirmed Design

- Keep eight TMEM banks; do not use bank replication as the first solution.
- Add consecutive-ready-ahead visibility to the overlapping Input and Weight
  LDMA executors. Occupied `WAIT_RSP` slots must not count as ready data.
- Add a TMEM-local one-bit urgency sideband. Do not reinterpret global memory
  flags.
- Hold address, tag, payload, and urgency stable while a source request stalls.
- Store Weight urgency in its wide-read context so every bank lane of a beat
  uses the same priority class until the partial issue completes.
- Arbitrate urgent requests before normal requests, retaining round-robin order
  within each class and bounded progress for normal requesters.
- Initially change only Input-versus-Weight policy: urgent Weight may overtake
  speculative Input prefetch only when Input has sufficient buffered lead.
- Parameterize tensor layout skew. Ordinary resources use TMEM-bank units;
  Weight uses `GEMM_WEIGHT_DATA_SIZE` wide-bank-group units, derived from the
  configured `MXU_WLOAD_NUM`, `MXU_COL`, and `W_BIT_WIDTH`.
- Default urgency and skew controls must reproduce the existing behavior when
  disabled.

## Scope

Expected scope includes, subject to source audit:

- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`
- `hw/rtl/mem/VX_tmem_wide_read_switch.sv`
- `hw/rtl/mem/VX_tensor_mem_bank.sv`
- Relevant TMEM switch interfaces and configuration/package declarations
- `kernel/src/fi_gemm.c` and layout/config plumbing for resource skew
- Directed unittests under `hw/unittest`
- RTL documentation and task `STATUS.yaml`

## Constraints

- No loss, duplicate, reorder, stale-version use, or unsafe overwrite.
- No new starvation of Input, tile DMA, Scale, ZP, or Output.
- Do not create a combinational cycle between urgency generation and TMEM
  `req_ready`.
- Weight address alignment is `GEMM_WEIGHT_DATA_SIZE`, not a fixed 64 B or
  fixed 128 B rule.
- Skewed producer and consumer addresses must remain identical and allocated
  regions must not overlap.
- Use the configured VCS flow and stop at the first confirmed design failure.

## Verification Contract

- Directed TMEM-bank arbitration: urgent-over-normal, RR within class, normal
  fallback compatibility, stable stalled requests, bounded fairness, reset.
- Directed Input/Weight overlap and wide-switch tests: ready-ahead semantics,
  stored priority across partial bank issue, eight contexts, ordering/fences.
- Existing DMA, qparam, GEMM unit/controller/sync, and node regressions.
- Node numerical matrix: M={4,256}, QDIR={QCOL,QROW}, N=K=256, QBLK=32,
  WTRANS=0, WLOAD=8.
- XRT-VCS baseline/skew/priority combinations followed by QCOL-first FSDB.
- Final performance target: every steady-state Weight command writes four
  consecutive beats and every operand-ready Input burst has zero internal and
  command-boundary gap, without starvation or new source bubbles.

## Hard Rule

Stop immediately and report if the confirmed arbitration/skew structure is
invalid: an unavoidable ready/urgency combinational loop, inability to keep
one stable priority across all Weight bank lanes, unbounded starvation,
invalid derived Weight group mapping/alignment, or evidence that policy changes
cannot meet the target with the physical eight-bank service bandwidth. Obvious
syntax, testbench, build, interface, or scoreboard drift is repairable and is
not a design blocker.
