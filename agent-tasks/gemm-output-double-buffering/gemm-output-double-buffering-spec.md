# GEMM Output Double Buffering Specification

Status: confirmed

## Goal

Turn the two physical accumulator groups into an execution double buffer so
that MXU compute on one group can overlap accumulator drain from the other,
while preserving explicit ownership, output-local-memory reuse, and final
completion dependencies.

The authoritative design and acceptance criteria are in
`docs/future_optim/gemv/gemm_improve/output_double_buf.md`.

## Scope

Phase 1 changes accumulator ownership dependencies in:

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/unittest/gemm_fsm/tb_VX_gemm_fsm.sv`
- `hw/unittest/gemm_ctrl/tb_VX_gemm_ctrl.sv`

Phase 2 changes group-aware accumulator arbitration in:

- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- relevant GEMM node/unit unittests

Phase 3 output-LMEM double buffering is explicitly out of scope.

## Confirmed Design Decisions

- Keep `RID_O` (RID 4) as the completed output-store count.
- Use RID 9 and RID 10 as cumulative ACC2LMEM completion counts for
  accumulator groups 0 and 1.
- Capture a tile-local reuse target from the selected group's ACC2LMEM issue
  count when a new output tile starts.
- Make every ARM command wait for that captured group-local reuse target.
- Make ACC2LMEM wait for the issued-store count, then SET the selected group's
  release RID to its next copy target.
- Make the paired DMA store wait for that copy target and increment `RID_O`.
- Make final drain wait for every issued DMA store.
- Expose the controller's current-cycle-effective completed output-store count
  to `VX_gemm_fsm` through a dedicated 32-bit module input. In
  `S_O_WAIT_LMEM2DRAM_FINAL`, compare that count directly against
  `o_store_issue_q`; do not substitute scheduler quiescence for this explicit
  dependency. The controller's existing quiescence gate remains the final
  queue/inflight-empty condition.
- Replace the global `pipeline_empty` output-read gate with a same-group
  conflict check that includes incoming and active/writeback compute accesses.
- Preserve output response ordering and prohibit simultaneous access to the
  same physical accumulator group.
- Do not add completion tags or change the command format.

## Constraints and Assumptions

- Each child executor has at most one active command and completes commands in
  issue order.
- Correctness must not depend on child FIFO depth or executor latency.
- Accumulator groups are physically separate memories.
- The output LMEM remains one global lifetime domain in this work.
- If implementation evidence contradicts the planned design, stop immediately
  and report the issue before proposing or applying a design change.
- The final-drain visibility gap reported on 2026-08-07 is resolved by the
  dedicated FSM input above. This preserves the source plan's exact counter
  semantics without changing the shared command format or sync-register map.

## Verification Contract

- Directed FSM metadata checks cover group RID/target capture, monotonic copy
  targets, paired ACC2LMEM/DMA-store dependencies, store-count targets, and
  final drain.
- Directed controller checks cover delayed ACC2LMEM, opposite-group progress,
  same-group blocking, same-cycle effective-sync release, delayed DMA store,
  and output-LMEM blocking.
- Node/unit checks prove different-group overlap and zero same-group conflicts,
  including same-cycle incoming compute.
- Functional unittests and configured XRT-VCS blackbox workloads pass for
  three-output-tile reuse, M/N edges, multiple K tiles, and backpressure.
- FSDB evidence shows nonzero MXU/ACC2LMEM overlap for different groups, zero
  same-group overlap, complete store retirement, empty queues/inflight state,
  and numerical parity with baseline.
