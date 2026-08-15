# GEMM Unit Backpressure Recovery Specification

Status: **Confirmed**

Parent task:
`agent-tasks/gemm-unit-backpressure-opt/gemm-unit-backpressure-opt-spec.md`

Source plan:
`docs/future_optim/gemv/gemm_improve/gemm_unit_backpressure_opt.md`

## Goal

Complete the unfinished Phase-1 verification gate without changing the
confirmed backpressure architecture, then proceed to the already-confirmed
Phase-2 two-bank W/S/Z consumer-readiness implementation.

## Recovery scope

- Replace the stale ACC early/coincident-read coverage stimulus with a
  post-launch-aware directed pattern.
- Use a same-QDIR, full-rate stream and explicit bank/address spacing so the
  post-launch classifier is guaranteed to observe:
  - a read that is not exact-address immediate/history forwarding;
  - a writer exactly `K_LOOKBACK` positions earlier on the same bank, selecting
    the one-cycle-early path;
  - a nominal read on another bank in the same cycle as the early request.
- Require correct early-hold data selection, ordered final writes, and nonzero
  early/coincident coverage. Do not waive or reduce forwarding coverage.
- Do not change production RTL unless verification exposes a genuine
  production failure. The expected first recovery edit is testbench-only.

## Phase-1 completion gates

Run, in order, with the configured VCS flow:

1. Legacy `gemm_unit_v2` full suite.
2. Focused `gemm_unit_v2_backpressure` suite.
3. `gemm_node_improve`, M=4, N=K=256, QBLK=32, WTRANS=0, WLOAD=8,
   QDIR=QCOL.
4. The same node test with QDIR=QROW.

Phase 1 passes only when all gates pass and the legacy suite reports nonzero
immediate, history, early, nominal, and cross-bank coincident nominal/early
coverage with complete ownership-queue drain.

## Phase 2 after Phase-1 PASS

Proceed exactly as specified by the parent specification:

- Remove Scale/ZP value snapshots from pipeline/FIFO payloads.
- Carry only exact W/S/Z bank and generation metadata.
- Check readiness at the actual resource consumer boundaries.
- Use independent two-bank WREG/SREG/ZREG resources and remove W2/W3 routes.
- Preserve resource-specific consume events, same-cycle old-read/new-write
  safety, LDMA overlap, ordered completion, and ACC/backpressure behavior.
- Run the full unit/node/XRT-VCS/FSDB verification plan.

## Hard Rule

The parent Hard Rule remains authoritative. Stop and report before changing
the concept if bounded backpressure, ACC ordering/forwarding, or exact W/S/Z
consumer generations cannot be preserved. Mechanical directed-test and build
compatibility fixes remain allowed.
