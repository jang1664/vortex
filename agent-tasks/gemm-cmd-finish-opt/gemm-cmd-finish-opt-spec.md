# GEMM command finish optimization spec

Status: **confirmed**

Authoritative plan:
`docs/future_optim/gemv/gemm_improve/gemm_cmd_finish_opt.md`

## Goal

Reduce non-final micro-K command completion latency without weakening final ACC
visibility. Preserve command-driven sync semantics: sync registers are updated
only by paired `OP_NOTIFY` commands.

## Scope

Apply directly to the current improved/V2 path:

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`
- `hw/rtl/VX_gpu_pkg.sv`
- relevant configured VCS unittests under `hw/unittest`

Do not modify the naive/legacy modules. Do not add `GEMM_IMPROVE_V2`.

## Confirmed design

1. Each `OP_I_LDMA_ARM` has exactly one paired `OP_NOTIFY` and one paired
   `WAIT RID_G[buffer]`.
2. FSM sets `notify_on_writeback=0` when the next consumer is another GEMM
   input and `notify_on_writeback=1` when the next consumer is
   `OP_O_ACC2LMEM`.
3. Non-final completion is qualified I_LDMA idle:
   command active, ingress done seen, and `input_dma_ctrl_if.idle`.
4. Final completion is tagged final writeback: delayed
   `notify_on_writeback`, delayed `last`, and `acc_write_fire`.
5. Raw idle and raw `last_write` must never complete a command without the
   corresponding qualification/tag.
6. `VX_gemm_ctrl` releases input child inflight using explicit
   `input_read_flag.done`, not the old idle-edge inference.
7. Paired NOTIFY is retained in the child queue until the selected completion
   occurs, then sync valid/ready handshake and queue pop occur atomically.
8. Remove `input_notify_pending_r` and the stored input NOTIFY RID/value
   registers. No replacement FIFO is allowed.
9. No GEMM writeback sync port, `RID_GW`, or `N_NODE=6` extension is allowed.
10. `RID_G0/RID_G1` use ADD-1 events. FSM maintains
    `gemm_expected_count[2]`, incremented only when ARM is accepted into the
    parent queue.
11. Expected counts reset on hardware reset and new GEMM invocation accept.
    32-bit wrap is unsupported and guarded by assertion.
12. Sync update is visible to WAIT on the next cycle. Do not add combinational
    bypass.
13. Reset during an active GEMM invocation/outstanding input or V2 pipeline is
    forbidden by assertion; reset clears all completion state.
14. Preserve the fixed `L_R/L_A/L_P=1/1/0` forwarding contract and final
    `pipeline_empty` output-read guard.

## Hard rule

If implementation reveals a problem with this agreed architecture, stop
immediately. Do not implement a substitute design. Report the failing premise,
evidence, and impact, then discuss and update the plan before resuming.

## Verification scope

Configured-build VCS unittests only for this implementation loop. Required
coverage includes:

- non-final initial idle cannot complete a command;
- non-final NOTIFY fires only after ingress-qualified LDMA idle and before raw
  writeback when timing permits;
- prior non-final raw writeback cannot release a final NOTIFY;
- final NOTIFY fires only after tagged final writeback;
- NOTIFY sync handshake and child queue pop are atomic;
- expected count increments exactly once on parent queue acceptance;
- final NOTIFY/WAIT precedes `OP_O_ACC2LMEM`;
- reset/CLEAR/count assertions;
- existing d=1/d=2/d=3 forwarding regression.

Blackbox/XRT-VCS is not part of this immediate loop unless the user expands the
verification scope after unit tests.
