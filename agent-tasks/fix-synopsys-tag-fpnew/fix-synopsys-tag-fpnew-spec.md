# Synopsys TAG and FPNEW INT64 Width Fix

## Goal

Fix the Synopsys elaboration failures observed in the naive GEMM FP16 target while preserving the intended runtime behavior:

1. Preserve the two routing bits required by the three-input PSUM write arbiter.
2. Support scalar FPNEW conversions involving INT64 when FP64 is disabled.

## Scope

- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/VX_core.sv`
- `hw/rtl/core/VX_mem_unit.sv`
- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`
- `third_party/cvfpu/src/fpnew_opgroup_multifmt_slice.sv`
- Focused RTL tests or lint/elaboration checks needed to verify these changes

The implementation may touch fewer files if the required width correction can be localized safely.

## Design Decisions

### PSUM write tag

- The PSUM read arbiter remains a 2-to-1 arbiter and requires one routing bit.
- The PSUM write arbiter is a 3-to-1 arbiter and requires two routing bits.
- The write path must carry the full `GEMM_BASE_TAG_WIDTH + 2` tag through the arbiter and across the core-to-memory-unit interface.
- Existing tag-resize helpers must preserve UUID placement and response routing information.
- Do not silence the mismatch through truncation or warning suppression.

### FPNEW INT64

- Keep INT64 enabled for RV64 scalar FP-to-integer and integer-to-FP conversions, including configurations with `EXT_D_DISABLE`.
- A scalar CONV lane must be wide enough for the widest active integer format as well as the active FP formats.
- The change must not enable FP64 or alter the non-CONV operation groups.
- Vector behavior must remain consistent with the existing per-lane format masks.

## Constraints and Assumptions

- Preserve the Vivado/FPU_DSP behavior.
- Preserve the existing PSUM arbitration priority and request/response routing.
- Follow the repository Verilog coding guidelines.
- Run tests only from a configured build directory and source the relevant configuration before simulation or synthesis.

## Final Agreed Spec

Status: **confirmed**

The user explicitly requested increasing the TAG bit width and resolving FPNEW by supporting the enabled INT64 path.
