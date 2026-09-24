# GEMM Command Stage Timing Specification

## Goal

Close the GEMM-node 7 ns OOC setup path from `VX_gemm_fsm.kt_dim_q` through
the microtile readiness admission probe into child command-queue BRAM input,
without reducing steady-state command issue throughput.

## Scope

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- Focused GEMM controller/node tests if additional coverage is required
- Existing `ci/run_gemm_node_ooc.sh` 7 ns OOC flow
- FPINT GEMM `xrt-vcs-sim` under
  `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`

Existing response-payload DPRAM experiments in the worktree are out of scope
and must be preserved without modification.

## Confirmed Design

1. Construct the FSM command payload from registered FSM state independently
   of downstream readiness. Readiness may control command acceptance and state
   advancement, but must not mux the wide payload to zero.
2. Insert one elastic command stage between the FSM output and the per-child
   command queues. The stage stores command payload, target child, and valid.
3. Support simultaneous stage drain and refill so the steady-state issue
   interval remains one command per cycle.
4. Preserve ordering, child selection, readiness-scoreboard accounting, and
   same-cycle functional contracts. A downstream command may acquire one cycle
   of latency, but no command-by-command bubble may be introduced.
5. Keep scoreboard admission associated with the exact command/work sequence;
   do not register a bare `probe_ready` bit that can become stale.

## Verification Targets

- Focused VCS regression covers command ordering, backpressure, simultaneous
  drain/refill, and completion behavior.
- FPINT GEMM passes in `xrt-vcs-sim`; measured cycles remain within 2% of the
  pre-change reference of 5,873 cycles for the existing 32x32x32 case.
- GEMM-node OOC synthesis at a 7 ns clock has no setup violation.
- The prior `kt_dim_q -> readiness probe -> child command BRAM` path is absent
  from the worst timing paths.

## Status

Confirmed on 2026-09-03. Implementation may proceed.
