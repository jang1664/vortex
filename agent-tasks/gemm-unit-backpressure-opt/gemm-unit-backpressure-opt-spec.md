# GEMM Unit Backpressure and Two-Bank Operand Lifetime Specification

Status: **Confirmed**

Source plan:
`docs/future_optim/gemv/gemm_improve/gemm_unit_backpressure_opt.md`

## Goal

Make `VX_gemm_unit_v2` lossless under arbitrary downstream backpressure without
adding a combinational ready path through the GEMM tree. After the backpressure
contract is proven, move Weight, Scale, and Zero-point readiness checks to their
actual consumer boundaries and return all three resources to independent
two-bank double buffering.

The final performance goal is one GEMM-tree launch per cycle, and therefore
back-to-back four-beat Input bursts, whenever the exact W/S/Z versions and ACC
group required by the corresponding transactions are ready.

## Confirmed phase ordering

1. Implement and verify pure GEMM-unit backpressure while preserving the
   current W/S/Z register count, readiness placement, and Scale/ZP value
   snapshots.
2. Only after Phase 1 passes, implement exact consumer-stage W/S/Z readiness,
   remove Scale/ZP value pipelines, and reduce Weight storage from four banks
   to two. Scale and Zero-point remain independent two-bank resources.
3. Run node, XRT-VCS, and FSDB performance checks only after the corresponding
   unit-level correctness gates pass.

## Phase 1 architecture

Partition the datapath into three regions:

```text
I-LDMA
  -> pre-process elastic ready/valid
  -> GEMM tree || ZP/activation-sum fixed-latency region
  -> combinational merge
  -> exact depth-6 merged-result FIFO
  -> post-process elastic ready/valid
  -> ACC memory commit
```

- Pre-process and post-process propagate ready combinationally only within
  their own regions.
- Do not add ready to or through `VX_gemm_tree_v1`.
- A single `compute_fire` launches both the GEMM-tree branch and correction
  branch. Both have exact latency five and must assert output valid together.
- Replace the existing depth-one merge output register with a dedicated
  depth-six merged-result FIFO; do not place the FIFO behind that register.
- Each FIFO entry carries the merged result and every post-process metadata
  field needed to preserve transaction identity. It does not carry Scale or
  Zero-point values in the final Phase-2 design.
- Use registered credit return across the tree boundary. With launch rate one,
  tree latency five, and ready-feedback latency one, six reservations are the
  mathematical minimum. A launch consumes one reservation; a FIFO pop returns
  one reservation through a register.
- Preserve the current ACC forwarding/read behavior and priority exactly:
  immediate forwarding, history forwarding, early hold, then nominal SRAM
  response. Do not introduce a new reservation-based ACC scheduler.
- Issue ACC reads only on the existing read-stage transaction handshake. Hold
  an already returned response until the accumulator consumes it, and retain
  same-bank overwrite protection and final `acc_write_fire` completion.
- All data and metadata move only on the same valid/ready handshake. Fixed
  tree latency is the sole exception and uses an aligned valid/metadata shift.
- `pipeline_empty` includes pre-process state, tree inflight state, result FIFO,
  post-process state, and pending ACC response/hold state.

## Phase 2 operand contract

- Input carries W/S/Z bank indices and exact LOAD generation/target metadata,
  not Scale/ZP values.
- W/S/Z readiness is checked immediately before the actual resource consumer:
  - Weight: common compute fork / GEMM-tree input.
  - QROW Scale: QROW input scaler.
  - QCOL Scale: QCOL output scaler.
  - QROW Zero-point: common-fork ZP multiplication.
  - QCOL Zero-point: readiness is fenced at the common fork, while the direct
    ZREG read occurs at ZP multiplication after activation reduction; writer
    lifetime must cover that actual read.
- Remove `qrow_scale_snapshot_q`, `qcol_scale_snapshot_pipe`,
  `qrow_zero_snapshot_pipe`, and `qcol_zero_snapshot_pipe` after Phase 1 passes.
  Pipeline only bank/version metadata.
- WREG, SREG, and ZREG each use two independently selected physical groups.
  Remove W2/W3 storage, selector, command, RID, and consume routes.
- Keep the current resource-specific consume-event overwrite contract. An old
  value may be read on the same edge that the exact next version is written,
  but the new version becomes ready only on the following cycle.
- Preserve the existing multi-command LDMA overlap engines, bounded response
  slots, writer fences, ordered completion, and completion-at-final-actual-write
  semantics.

## Required invariants

- `0 <= tree_credit <= 6`.
- `tree_inflight + merged_fifo_occupancy <= 6`.
- Every `compute_fire` owns exactly one eventual FIFO entry.
- Tree and correction output valid are equal for every transaction.
- A merged output is never produced without reserved FIFO capacity.
- Under `valid && !ready`, data and all metadata remain stable.
- Accepted, launched, merged, popped, and committed transaction counts agree
  after drain; no loss, duplicate, or reorder is permitted.
- ACC forwarding source selection and response ownership remain identical to
  the pre-change protocol.
- Phase 2 may release a resource stall only for the exact matching bank and
  generation, and may not overwrite before the final actual consumer.

## Verification gates

### Phase 1

- Directed `gemm_unit_v2` VCS tests for QCOL and QROW with post-process stalls
  of 1, 2, 6, and 7 cycles, full-rate first-output stall, nonempty FIFO
  stop/resume, deterministic and random backpressure, reset while occupied,
  stability, count/order, valid alignment, credit, and ACC forwarding checks.
- W/S/Z load timing and Input burst gap are not Phase-1 pass/fail metrics.

### Phase 2

- Independently delay W/S/Z LOAD generations and prove each transaction stalls
  only at its actual consumer boundary, ignores stale/other-bank generations,
  advances after exact readiness, and respects consume/overwrite lifetime.
- Cover QCOL/QROW consumer differences, two-bank wraparound, same-cycle old
  read/new write, and absence of Scale/ZP values from pipeline/FIFO payloads.
- Re-run Input/Weight/Scale/ZP overlap, generic LDMA, controller/FSM/sync, and
  GEMM-unit/node VCS regressions.

### Integration

- `gemm_node_improve`: M={4,256}, QDIR={QCOL,QROW}, N=K=256, QBLK=32,
  WTRANS=0, WLOAD=8.
- XRT-VCS numerical matrix through the repository target-GEMM wrapper.
- M=4 QCOL/QROW FSDB inspection of pre-process accept, compute launch,
  tree/correction output, FIFO push/pop, ACC commit, exact W/S/Z stalls, and
  back-to-back Input bursts when operands are ready.

## Hard Rule

Stop immediately and report evidence if the planned architecture cannot
preserve arbitrary-backpressure correctness with bounded FIFO/credit, cannot
preserve the existing ACC response/forwarding order, or cannot carry exact
W/S/Z generations to their real consumers. Discuss a revised architecture
before continuing.

Mechanical Makefile/script/testbench/interface/simulator compatibility fixes
that do not change the confirmed design are allowed without stopping.
