# GEMM Unit V2 XRT Integration Specification

**Status**: complete

## Goal

Execute `docs/future_optim/gemv/gemm_improve/xrt_vcs_integration_plan.md`:
harden the `VX_gemm_node` command-to-packet metadata path for
`VX_gemm_unit_v2`, verify the RTL at unit and node level, and pass the directed
`fpint_gemm_ffn_hw` `xrt-vcs-sim` matrix.

## Scope

Primary implementation files:

- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`

Conditional files, changed only when evidence requires it:

- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`
- XRT-VCS source/build files

## Required Design

1. Capture decoded input-command context in `VX_gemm_node`.
2. Generate exactly one `gemm_input_ctrl_t` for each accepted input request.
3. Use `cmd.rs1_data`, `cmd.eff_mt`, and `cmd.flags` from the active job-FSM
   path as semantic sources.
4. Advance packet address/index only on `req_valid && req_ready`.
5. Preserve the command-start/first-input same-cycle case.
6. Keep the command busy after final input admission until V2 `last_write`.
7. Drive command completion exactly once from the delayed final writeback.
8. Keep V2 always-ready, fixed-latency, and free of command/address FSMs.
9. Preserve V2 forwarding and early-read ownership.
10. Add node-boundary assertions and an independent node metadata scoreboard.

## Constraints

- Do not change V1, `VX_gemm_node_naive`, or the V1 unittest.
- Do not change kernel command encoding or `VX_gemm_fsm` without blackbox
  evidence that the decoded command contract is wrong.
- Do not run synthesis, hardware emulation, or FPGA hardware tests.
- Run RTL verification with VCS from the configured build.
- Run blackbox verification only through the `run-bb-common` procedure.

## Required Verification

- `hw/unittest/gemm_unit_v2` VCS regression.
- `hw/unittest/gemm_node_improve`:
  - `M=32, N=32, K=32`;
  - `M=32, N=32, K=128`;
  - a GEMV-shaped `M=1, K=64` case or equivalent metadata-directed coverage.
- `fpint_gemm_ffn_hw` `xrt-vcs-sim` directed cases from the integration plan,
  including M1 multi-K accumulation and `M=32, N=32, K=128`.
- Selected weight-transpose and QROW variants.

## Completion

Completion requires all criteria in section 10 of the integration plan to be
proven from the current RTL, unittest results, and xrt-vcs logs.
