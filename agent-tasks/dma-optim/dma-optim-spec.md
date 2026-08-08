# DMA Look-Ahead Optimization Specification

Status: confirmed
Source: `docs/future_optim/gemv/gemm_improve/dma_optim.md`
Confirmed: 2026-08-07

## Goal

Reduce aligned-DMA command-accept-to-first-request latency and prepared
previous-completion-to-next-request latency by at least one cycle while
preserving functional behavior and the existing request-level outstanding
mechanism.

## Scope

- Refactor `hw/rtl/core/VX_dma_unit_align.sv` to launch the initial segment
  while D0/D1 correction products are calculated, with independent safe
  rollover waits.
- Add controller-owned two-slot command look-ahead in
  `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`.
- Add a dedicated PREPARE/ACTIVATE interface and route it through the GEMM
  node, TMEM subsystem, `VX_dma_engine.sv`, and `VX_dma_unit.sv` to the aligned
  backend.
- Keep full descriptors and all scheduling decisions in the controller. Each
  aligned channel stores only two tagged precalculation-result slots.
- Extend directed RTL verification and `ci/run_target_gemm.sh` as required by
  the source plan.

## Design Decisions

- PREPARE and ACTIVATE are distinct. PREPARE cannot trigger the legacy
  descriptor `cfg_fire` or reset active DMA/AXI bookkeeping.
- The controller owns an oldest-high-priority candidate and a fallback
  paused-store/oldest-low-priority candidate. A global one-bit `prep_id`
  indexes random-access prepared slots across all active channels.
- Input-load priority, paused-store semantics, speculative cursor handling,
  and physical-completion/B-drain safety follow the source plan exactly.
- Positive-size aligned descriptors use the fast first-segment path. Corner
  cases outside that contract use the legacy start path.
- D0 advance needs no product; D0-to-D1 carry needs D0 corrections;
  D1-to-D2 carry needs D0 and D1 corrections; final completion needs none.
- PREPARE cancellation and same-cycle released-slot reuse are excluded from
  the initial implementation.
- `VX_dma_unit_misal.sv`, CPU DMA, and local DMA retain legacy behavior.

## Constraints and Assumptions

- Do not alter `RD_OUTSTANDING`, request/response tag layout, response-slot
  depth, request-buffer parameters, HBM topology, or store-chunk policy.
- ACTIVATE is legal only after all active channels are physically complete
  and all HBM write responses have drained.
- A late high-priority load suppresses fallback activation even when not
  prepared; it uses the existing slow build path.
- The source plan's hard rule applies: if the confirmed architecture is found
  to be invalid during execution, stop immediately and report the design
  problem before proposing or implementing a different design.

## Acceptance

- Directed aligned-DMA and controller/integration tests cover all Phase 1–7
  cases from the source plan, including rollover dependencies, slot ordering,
  PREPARE isolation, same-edge chaining, priority, backpressure, delayed B
  responses, and speculative store commit.
- Configured aligned regressions pass using `/usr/bin/gcc` and `/usr/bin/g++`
  where host compilation is involved.
- `ci/run_target_gemm.sh` supports `--m`, defaults to M=4, passes `-m` to the
  application, and records M in run tags/manifests.
- XRT-VCS WLOAD=8 M/K/N cases 4/256/256 and 256/256/256 are numerically
  correct, with total cycles, command counts, and requested look-ahead metrics
  reported against a matched baseline.
- Command-accept-to-first-request and prepared chaining latency each improve
  by at least one cycle in their matching cases.
- `VX_dma_unit_misal.sv` remains unchanged and legacy CPU/local DMA behavior
  passes regression.

