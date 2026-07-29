# GEMM_NAIVE PSUM Mixed-Set Outstanding Reads

## Goal

Improve GEMM_NAIVE performance with multiple outstanding PSUM reads from one
LMEM bank set at a time, while preserving correctness and avoiding a large new
payload buffer.

## Scope

- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`
- Preserve drain-before-switch serialization between PSUM bank sets, but issue
  a bounded batch from one address-stream parity before selecting the other.
- Preserve queued-write ordering, same-cycle read/write conflict protection,
  PSUM FIFO/credit behavior, final-write queue depth 4, and accumulator bank
  decode fixes.
- Fresh exact-config XRT-VCS verification for M256/K256/N256, followed by
  M64 and M128 K256/N256 regressions if the primary case passes.

## Baseline

- M256/K256/N256: 177,213 cycles.
- The trace contains 112 accumulate commands.
- Each command waits 365-372 cycles from its first PSUM read until input starts,
  after 30 FIFO pushes.
- Accumulated first-read-to-input delay is 41,354 cycles (23.3% of total).
- A 128-row PSUM read stream spans 1,335 cycles on average.

## Design Decisions

- Iteration 1 used existing lane request/response skid buffers and PSUM response
  tags while allowing both sets to overlap. It failed because physical bank
  responses reordered differently across lanes, producing an incoherent wide
  response.
- Iteration 2 restores the active-set/outstanding drain-before-switch guard and
  changes the read selector to batches of eight requests from one parity.
- Eight requests match the existing per-lane response skid depth of eight and
  consume at most half of each parity FIFO's sixteen credits. The controller
  then drains the batch before switching parity.
- Track unit-side accepted-minus-returned requests so every batch is bounded
  even when the alternate parity is temporarily ineligible.
- Retain pending/current PSUM write conflict blocks.
- Do not add a wide PSUM payload FIFO.
- Resource delta relative to iteration 1 is sixteen control flip-flops: restored
  7-bit node outstanding count plus 1-bit active set, and a 3-bit burst count,
  4-bit unit outstanding count, plus 1-bit drain flag. The existing selector is
  reused and no data RAM or payload register is added.

## Constraints and Assumptions

- Use `configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`.
- Confirm `GEMM_NAIVE`, `NUM_THREADS=16`, `L1_MEM_PORTS=2`, and
  `MXU_COL_TILE=32` in every fresh VCS compile.
- Treat output mismatch, PSUM shadow mismatch, fatal/assertion, FIFO/credit
  issue, timeout, or deadlock as failure.
- Compare kernel cycles against the 177,213-cycle baseline; VCS wall time and
  trace size are not performance metrics.

## Confirmed Specification

Issue up to eight same-parity PSUM reads concurrently, drain all their wide
responses, and only then switch physical bank sets. Preserve per-parity FIFO
credits and alternating consumption so both FIFOs reach their almost-full
startup watermark. Accept the change only if M256 correctness passes with
lower cycles and M64/M128 do not regress.
