# GEMM Low-Latency Floating-Point IP Specification

## Goal

Reduce the synthesis latency of the floating-point multipliers and adder used by
`VX_gemm_unit` by generating dedicated Xilinx Floating-Point IP variants.

## Scope

- Add dedicated floating-point IPs in `hw/scripts/xilinx_ip_gen.tcl` whose
  module names use the `_low_latency` postfix.
- Make only the floating-point operations instantiated by
  `hw/rtl/core/gemm/VX_gemm_unit.sv` select those dedicated IPs.
- Preserve the existing IP modules and their users.
- Keep simulation and non-Xilinx implementation behavior aligned with the new
  effective latency.

## Design Decisions

- The dedicated IPs retain the operand precision, operation type, handshake,
  clock-enable, and reset settings of their existing counterparts.
- Wrapper modules expose an explicit selection parameter so other users keep
  using the original IP by default.
- `VX_gemm_unit` opts into the low-latency variants at each FP multiplier and
  adder instance.
- Pipeline latency constants in `VX_gemm_unit` must match the generated IP
  latency after accounting for wrapper buffering.

## Constraints and Assumptions

- No existing unrelated worktree changes may be modified.
- IP generation must remain compatible with Xilinx Floating-Point IP version
  7.1.
- Verification uses the existing GEMM unit test through `tools/verify_rtl.py`.
- Full Vivado IP generation is performed only if the required external tools
  are available in the configured environment.

## Final Agreed Specification

**Status: confirmed**

Generate separately named low-latency FP multiply/add IPs with the
`_low_latency` postfix and update `VX_gemm_unit` to select them without changing
the default IP choice for other RTL users.
