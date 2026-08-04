# Target GEMM WLOAD8 Runner Specification

**Status**: confirmed

## Goal

Provide one reproducible `ci/run_target_gemm.sh` entry point for the GEMV-like
target workload (`M=4`) and make the workload pass with `MXU_WLOAD_NUM=8`.

## Fixed configuration

- Config: `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`
- App: `fpint_gemm_ffn_hw`
- Driver: `xrt-vcs-sim`
- Target M: 4
- Default shape: `M=4, N=256, K=256, QBLK=32, WTRANS=0, QDIR=1`
- Default perf class: 3

The script must reject a sourced config that does not contain both
`GEMM_IMPROVE` and `MXU_WLOAD_NUM=8`.

## Runner modes

- `run`: no FSDB and no RTL trace; default fast functional/performance run.
- `trace`: no FSDB, with selected GEMM trace defines.
- `fsdb`: full-design FSDB with the same workload and config.
- `fsdb-gemm`: GEMM-only FSDB with the same workload and config.
- `fsdb-trace`: full FSDB plus GEMM traces.

All modes must use the configured build directory and `ci/run_black.sh`, apply
a timeout, print the exact effective command/config, and preserve a
timestamped manifest, wrapper log, VCS compile log, simv log, and waveform
when enabled.

## Rebuild contract

The script must avoid stale XRT-VCS binaries. It should force `simv` rebuild
when requested, when the effective compile configuration changes, or when
relevant source RTL/testbench files are newer than `simv`.

## Scope

Primary files:

- `ci/run_target_gemm.sh`
- `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`

Conditional evidence-driven files:

- `hw/rtl/VX_config.vh` for external `MXU_WLOAD_NUM=8` override support.
- `sim/xrtsim_vcs/tb_vcs_xrtsim.sv` for GEMM-only FSDB support on
  `GEMM_IMPROVE`.
- WLOAD datapath RTL only if the target blackbox exposes a real defect.

## Verification

1. `bash -n` and `--help` for the runner.
2. Confirm preprocessing/elaboration uses `MXU_WLOAD_NUM=8`, not the default
   value 4.
3. Run the default `M=4` workload without FSDB.
4. Require app `PASSED`, normal completion, and no VCS fatal/error.
5. Smoke-check FSDB mode setup without requiring a full waveform run if the
   functional target already proves WLOAD8 and full FSDB runtime is excessive.

Synthesis, hardware emulation, and FPGA hardware runs are out of scope.
