# GEMM Command-Overlap Trace Specification

Status: confirmed by the user on 2026-08-07.

## Goal

Add simulation-only observability that measures the lifecycle and overlap of
commands emitted by `VX_gemm_fsm`. The primary evidence must compare
`M=4` and `M=256`, show whether tile double buffering hides preload latency,
and show whether an output DRAM store is hidden by useful later-tile work.

## Source Plan

The detailed and user-approved design is:

`docs/future_optim/gemv/gemm_improve/fsm_command_overlap_trace_plan.md`

That document is normative for interval definitions, record fields,
structured output markers, invariants, verification, and completion criteria.

## Scope

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- Relevant VCS unit tests under `hw/unittest/`
- A structured-log summarizer under `tools/`
- This task's `STATUS.yaml` and related GEMM documentation

## Confirmed Design Decisions

1. Track `emit`, executor `issue`, and architectural `done` as distinct
   lifecycle boundaries using half-open service intervals.
2. Preserve normalized tile/buffer metadata at FSM emission; do not infer it
   later from overloaded command operands.
3. Keep all new ports, state, assertions, and trace output under
   `ifndef SYNTHESIS` plus `DBG_TRACE_GEMM_CMD_PERF`.
4. Do not modify `gemm_unified_cmd_t`, synthesized payload widths, scheduling
   behavior, or the performance CSR ABI.
5. Distinguish command logical overlap from actual DMA descriptor ownership.
6. Dump structured records once per fully drained GEMM invocation.
7. `M=4` and `M=256` are mandatory. Use `M=384` only as a diagnostic control
   because the two-tile `M=256` geometry has no tile-2 load that can overlap
   store 0.
8. Preserve all existing multi-command DMA worktree changes.

## Fixed Workloads

```text
M=4,   N=32, K=128, QBLK=32, WTRANS=0, QDIR=0
M=256, N=32, K=128, QBLK=32, WTRANS=0, QDIR=0
M=384, N=32, K=128, QBLK=32, WTRANS=0, QDIR=0  # control
```

## Constraints

- Simulation results must remain numerically identical with tracing enabled
  and disabled.
- The instrumentation must compile away under `SYNTHESIS`.
- Accounting inconsistencies must fail simulation rather than emit partial or
  misleading summaries.
- FSDB is optional and is not the primary reporting mechanism.

## Final Agreed Specification

Confirmed. Implement the source plan without expanding performance registers
or changing functional scheduling.
