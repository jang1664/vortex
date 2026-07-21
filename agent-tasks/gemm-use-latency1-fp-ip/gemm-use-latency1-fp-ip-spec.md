# GEMM Latency-1 Floating-Point IP Specification

## Goal

Switch the floating-point multipliers and accumulator adder used by
`VX_gemm_unit` from the latency-2 Xilinx IP variants to the latency-1 variants.

## Scope

- Extend the FP16 multiply, FP32 multiply, and FP32 add wrappers to select the
  corresponding `*_latency1` module.
- Make only `VX_gemm_unit` select latency-1 IPs.
- Include the latency-1 XCI files in Xilinx synthesis, XRT packaging, and Xilinx
  VCS IP compilation lists.
- Align FPNEW/DPI simulation buffering with one-cycle hardware latency.
- Preserve the default and latency-2 choices for other wrapper users.

## Design Decisions

- Keep the existing latency-2 `_low_latency` selection available.
- Add a separate default-off latency-1 selection parameter to each wrapper.
- Select latency 1 in GEMM and remove the modeled output-buffer cycle while
  keeping the zero internal simulation latency.

## Constraints and Assumptions

- The latency-1 IP definitions already exist in `hw/scripts/xilinx_ip_gen.tcl`.
- The latency-1 output is combinational after the IP's internal register, so
  full-design timing may be more difficult than with latency 2.
- Preserve all unrelated worktree changes.
- Verify with the configured-build GEMM unit VCS test.

## Final Agreed Specification

**Status: confirmed**

Use the generated latency-1 FP16 multiplier, FP32 multiplier, and FP32 adder IPs
inside `VX_gemm_unit`, with matching one-cycle simulation behavior and complete
Xilinx build-flow integration.
