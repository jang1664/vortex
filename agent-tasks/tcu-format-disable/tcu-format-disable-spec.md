# TCU FP16/BF16 Format Disable Specification

Status: confirmed

## Goal

Allow a TCU build to retain only the FP16 or only the BF16 floating-point
input datapath so unused BHF multiplier hardware can be removed at
elaboration. Existing builds must continue to support both formats by default.

## Scope

- `hw/rtl/VX_config.vh`
- `hw/rtl/tcu/VX_tcu_fp.sv`
- `hw/rtl/tcu/VX_tcu_fedp_bhf.sv`
- `hw/rtl/tcu/VX_tcu_fedp_dsp.sv`
- `hw/rtl/tcu/VX_tcu_fedp_dpi.sv`
- TCU RTL documentation under `docs/rtl/tcu/`
- Functional validation with `sgemm_tcu` in `xrt-vcs-sim` mode

The standalone Synopsys TCU script is excluded because it has pre-existing
worktree modifications and is not required for the requested functional test.

## Design Decisions

- Use the corrected macro spelling consistently:
  - `DISABLE_BF16` creates an FP16-only TCU.
  - `DISABLE_FP16` creates a BF16-only TCU.
- With neither macro defined, both FP16 and BF16 remain supported.
- Defining both macros is an invalid configuration and must fail at compile or
  elaboration.
- The BHF backend must use preprocessor guards to prevent elaboration of the
  disabled `VX_tcu_bhf_fmul` instances.
- DPI and DSP backends must honor the same supported-format contract.
- A request for a disabled format must be detected in simulation at the
  `VX_tcu_fp` request boundary.
- Interfaces, format IDs, accumulation precision, and pipeline latency remain
  unchanged.

## Constraints and Assumptions

- Do not change integer TCU behavior.
- Do not remove software or simulator type definitions.
- Do not change ISA encoding.
- Preserve warning-free RTL in all three legal configurations.
- Use a configured build directory and source a
  `configs/naive_simd_*_th16.sh` configuration before testing.
- Run blackbox verification through `ci/run_black.sh xrt-vcs-sim`.

## Acceptance Criteria

- Default dual-format build elaborates both BHF multiplier families.
- `DISABLE_BF16` passes an FP16 `sgemm_tcu` test and omits BF16 BHF
  multipliers.
- `DISABLE_FP16` passes a BF16 `sgemm_tcu` test and omits FP16 BHF
  multipliers.
- Both macros together are rejected.
- Disabled-format requests fail clearly in simulation.
- Existing TCU latency and handshaking are unchanged.
