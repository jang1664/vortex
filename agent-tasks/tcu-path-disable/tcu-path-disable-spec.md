# TCU FP/INT Path Disable Specification

Status: confirmed

## Goal

Allow builds to remove the complete floating-point or integer TCU execution
path. The default configuration must retain both paths. When only one path is
enabled, the request and result channels must connect directly without
elaborating the two-way PE switch or unused internal interfaces.

## Configuration Contract

- No path-disable macro: enable both FP and INT paths.
- `DISABLE_TCU_INT`: enable only the FP path.
- `DISABLE_TCU_FP`: enable only the INT path.
- Defining both path-disable macros is an invalid configuration and must fail
  compilation or elaboration.
- `DISABLE_FP16` and `DISABLE_BF16` remain independent FP sub-format controls
  when the FP path is enabled.
- The integer path is controlled as one unit. I8, U8, I4, and U4 are all
  present when enabled and all removed by `DISABLE_TCU_INT`.

## Structural Design

- In the default dual-path build, retain the existing two-way `VX_pe_switch`
  selected by `fmt_s[3]` and instantiate both `VX_tcu_fp` and `VX_tcu_int`.
- With `DISABLE_TCU_INT`, instantiate only `VX_tcu_fp` and connect the
  per-block execute/result interfaces directly to it.
- With `DISABLE_TCU_FP`, instantiate only `VX_tcu_int` and connect the
  per-block execute/result interfaces directly to it.
- Do not elaborate `VX_pe_switch`, its two-element execute/result interface
  arrays, or the disabled TCU instance in either single-path build.
- Preserve dispatch, gather, block count, lane count, handshaking, metadata,
  and enabled-path pipeline latency.
- Add simulation assertions at the accepted per-block request boundary to
  reject an integer request in an FP-only build or an FP request in an
  INT-only build.

## Scope

- `hw/rtl/VX_config.vh`
- `hw/rtl/tcu/VX_tcu_unit.sv`
- TCU documentation under `docs/rtl/tcu/`
- `hw/syn/synopsys/syn_tcu.py` so its FP-only synthesis configuration also
  removes the integer path
- Verification using the configured VCS/XRT build flow

## Verification

- Compile/elaborate the default dual-path configuration.
- Compile/elaborate FP-only with `DISABLE_TCU_INT`, including both dual-format
  FP and `DISABLE_BF16` FP16-only variants.
- Compile/elaborate INT-only with `DISABLE_TCU_FP`.
- Confirm both path-disable macros together are rejected.
- Run `sgemm_tcu` in xrt-vcs-sim mode for:
  - FP-only plus `DISABLE_BF16`, with FP16 input and FP32 output.
  - INT-only with I8 input and I32 output.
  - INT-only with I4 input and I32 output when supported by the test variant.

## Non-Goals

- Adding I32, I16, or U16 integer multiplication support.
- Disabling individual integer formats independently.
- Changing format IDs, instruction encoding, tile dimensions, or arithmetic
  pipeline latency.
