# GEMM Unit Backpressure Recovery 2 Specification

Status: **Confirmed**

Parent task:
`agent-tasks/gemm-unit-backpressure-opt/gemm-unit-backpressure-opt-spec.md`

Prior recovery:
`agent-tasks/gemm-unit-backpressure-opt-recovery/gemm-unit-backpressure-opt-recovery-spec.md`

Source plan:
`docs/future_optim/gemv/gemm_improve/gemm_unit_backpressure_opt.md`

## Goal

Continue Phase-2 verification after the prior recovery loop reached its 10/10
limit. Preserve the confirmed GEMM-unit backpressure, ACC forwarding, exact
W/S/Z consumer-readiness, two-bank resources, and LDMA-overlap architecture.

The initial recovery is a mechanical legacy-testbench correction. The directed
non-last-QCOL consumer-metadata test must remain a legal member of the strict
ACC address stream while retaining the intended QCOL-bank0/QROW-bank1 metadata
overlap.

## Iteration-1 scope

- Change only `hw/unittest/gemm_unit_v2/tb_VX_gemm_unit_v2.sv` and this
  recovery task's documentation.
- Keep the first non-final QCOL packet at ACC address zero.
- Change the following non-accumulating QROW packet from address zero to
  `ACC_ROW_BYTES` for both ACC address fields through the common packet driver.
- Preserve QCOL W/S/Z bank 0, held QROW W/S/Z bank 1, the forced QROW consumer
  stall, the non-final QCOL Scale/ZP metadata checks, and the
  `NONLAST_QCOL_CONSUMER_METADATA_PASS` marker.
- Do not change production RTL, resource lifetimes, consumer metadata,
  backpressure, FIFO credits, ACC scheduling, or completion behavior.

## Verification gates

Run with the configured VCS flow, in order:

1. Legacy `gemm_unit_v2` full suite.
2. Focused `gemm_unit_v2_backpressure` suite.
3. `gemm_node_improve`, QCOL then QROW for each M in `{4,256}`, with
   N=K=256, QBLK=32, WTRANS=0, and WLOAD=8.
4. Matching XRT-VCS target-GEMM numerical matrix after all unit/node gates pass.

Preserve prior PASS evidence for gemm_sync, FSM, gemm_ctrl, lmem_dma_misal,
and the Input/Weight/Scale/Zero-point overlap executors because iteration 1
changes only the legacy unit testbench.

The legacy gate must report the non-last-QCOL marker, retain scaler=M,
ACC=M+2, write=M+3 alignment, preserve immediate/history/early/nominal ACC
coverage, keep QCOL ZP lifetime counters valid, and drain all ownership queues.

## Hard Rule

The parent Hard Rule remains authoritative. Stop and report before changing the
architecture if bounded backpressure, ACC ordering/forwarding, or exact W/S/Z
consumer generations cannot be preserved. Mechanical testbench address repair
is explicitly in scope and is not a blocker.
