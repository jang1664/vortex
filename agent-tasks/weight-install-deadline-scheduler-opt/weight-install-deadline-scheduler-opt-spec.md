# Weight Install Deadline Scheduler Optimization Spec

Status: confirmed

## Goal

Reduce Weight-generation deadline misses and the resulting held-valid Input gaps by scheduling against the time at which Weight becomes consumer-visible, rather than only descriptor fetch completion.

## Confirmed causal model

The existing Input stream stays within its physical and configured response-slot budgets, but Input P2 traffic at occupancy 2--3 often wins the same TMEM bank over nearby Weight traffic. The delayed final Weight response then leaves less than the fixed response-drain, register-write, and registered-generation-visibility latency. This misses the Weight double-buffer handoff deadline, stalls the GEMM consumer, and backpressures an already-valid Input transaction.

The root cause is insufficient end-to-end Weight lead time. It is neither an unsafe Input overfetch nor an independently variable writer latency.

## Scope

- Derive a registered Weight deadline class from authoritative descriptor progress, work distance, and Input progress/admission state.
- Split Input starvation recovery, minimum service, and ahead service.
- Promote only fetch-pending critical Weight work; fetch-complete/install-pending resources remain background priority.
- Protect a critical Weight command's final logical request or completion lane without using P3 unless an actual registered consumer block still has fetch work.
- Preserve fixed request payload and priority while `valid && !ready`.
- Add directed tests, node regressions, XRT-VCS coverage, and strict FSDB measurements.

Primary production files:

- `hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`, only if a registered admission/deadline signal is required
- Existing LDMA/TMEM progress interfaces, only if completion-lane metadata is not already available

## Design decisions

- Use registered SAFE/NEAR/CRITICAL classes before attempting an exact cycle predictor.
- Include the fixed response-to-write and write-to-visible latency in the criticality contract.
- Use descriptor-derived totals and progress; do not encode WLOAD, QBLK, or tile-specific beat constants.
- Input occupancy zero is starvation recovery P3; occupancy one is minimum service P2.
- When enough Input is already buffered and a fetch-pending Weight is CRITICAL, Weight is P2 and additional Input is P1.
- A fetch-complete or install-pending Weight request is P0.
- P3 for Weight requires an actual registered consumer block and remaining fetch work.
- Same-tier round-robin, cross-tier fairness escape, capacity bounds, generation ownership, and writer ordering remain unchanged.

## Constraints

- No new Weight storage bank, write-data forwarding, final-completion forwarding, or out-of-order install.
- No combinational path from GEMM ready or final register write to scheduler priority, source enable, or GEMM ready.
- No live reprioritization of a request already presented to TMEM.
- No unbounded starvation of Input, Scale, Zero Point, Output, or general DMA.
- Preserve the dirty worktree and the previously verified microtile-readiness scheduler baseline.

## Required verification

- Focused scheduler, LDMA/wide-switch, controller, unit, and backpressure VCS tests.
- Fixed 8/8/8 node matrix for M={4,256}, QDIR={QCOL,QROW}.
- Matching XRT-VCS blackbox matrix through `ci/run_black.sh`/repository wrapper with a forced first rebuild.
- Rebuilt M4 QCOL FSDB proving that the priority change affects bank grants and increases final-response lead without correctness, fairness, or capacity regressions.

## Completion criteria

- Critical Weight no longer loses bank service to Input ahead traffic except a bounded fairness escape.
- Weight-caused steady-state held-valid Input gaps are eliminated or reduced to a separately explained bounded exception.
- Numerical results, metadata order, generation/lifetime safety, request stability, and all fixed 8/8/8 regressions pass.
- M4 cycle counts do not regress from 628/625 and M256 does not regress by more than 0.5% from 19427 cycles.
