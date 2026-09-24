# GEMM Unit V2 Stateless Pipeline Specification

Status: confirmed

## Goal

Implement the stateless fixed-latency GEMM input/accumulation pipeline described in `docs/future_optim/gemv/gemm_improve/plan.md` for the `GEMM_IMPROVE` path. The new pipeline must accept one input packet every cycle without backpressure, align all packet metadata with the arithmetic pipeline, and schedule ACC-memory reads with the documented one-cycle-early rule.

## Scope

Primary implementation files:

- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv` (new)
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv` (new)
- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- explicit source lists that compile `VX_gemm_node`
- `hw/unittest/gemm_unit_v2/**` (new)

Reference-only files that must remain behaviorally intact:

- `hw/rtl/core/gemm/VX_gemm_unit.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_if.sv`
- `hw/unittest/gemm_unit/**`
- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`

## Design Decisions

1. V2 is a separate module and interface. Do not add a large v1/v2 preprocessor branch inside `VX_gemm_unit.sv`.
2. `VX_gemm_node` uses V2; `VX_gemm_node_naive` continues to use V1.
3. ACC read/write enables, byte addresses, mode, register selections, and last-packet metadata are generated outside V2 and arrive with the input packet.
4. The input request ready signal is permanently high. An accepted packet cannot be stalled, replayed, or dropped.
5. Data and metadata follow fixed-latency pipelines. QCOL/QROW and load/accumulate paths must be latency-aligned so command changes cannot corrupt older packets.
6. ACC reads use the rule from `one_cycle_early_acc_read_scheduling_derivation.md`:
   - `K = L_A + L_P + L_R`
   - compare the current read bank with the write bank of the valid packet admitted exactly K cycles earlier
   - issue nominally when there is no conflict and exactly one cycle early when there is a conflict
7. Nominal and early requests may coincide for different physical banks. Generate per-bank request vectors, not a scalar arbitration point.
8. Early data may be retained for one cycle in a one-entry per-bank holding register. Do not port V1's prefetch FIFO, credit accounting, or round-robin read scheduler.
9. Completion is the actual ACC write of the packet marked `last`, not an FSM state transition.
10. Output reads are allowed only after the V2 compute pipeline is empty in this phase.

## Constraints and Assumptions

- One input packet maximum per cycle.
- Packet order is preserved.
- ACC addresses advance by `GEMM_PSUM_DATA_SIZE` and obey the strict ping-pong mapping assumed by the derivation.
- ACC SRAM has fixed read latency and single-cycle port occupancy.
- Every valid packet with write enable produces exactly one write at the fixed write delay.
- Verification is limited to RTL unittests. Do not run blackbox or top-level simulation in this task.
- Use the configured build directory, source `configs/improve_th32_tcol32_hwexp_dcache.sh`, and use VCS through `tools/verify_rtl.py`.

## Required Verification

- V2 compile and numerical load/accumulate correctness for QCOL and QROW.
- Continuous one-packet-per-cycle input with zero ready stalls.
- Bubble handling with per-packet fixed write delay.
- Address, enable, register-index, mode, and last metadata alignment across command boundaries.
- Nominal read, one-cycle-early read, K-cycle bubble, different-bank, coincident cross-bank request, and bank-group boundary cases.
- No same-bank read/read or read/write collision.
- No early-hold overwrite, missing PSUM, dropped write, duplicate write, reorder, stale valid, or ghost write after reset.
- Existing V1 source and unittest remain available as the reference implementation.

## Final Agreed Specification

Confirmed by the user's request to execute `docs/future_optim/gemv/gemm_improve/plan.md`, including the follow-up decision to implement a separate `VX_gemm_unit_v2.sv` instead of an internal preprocessor split.
