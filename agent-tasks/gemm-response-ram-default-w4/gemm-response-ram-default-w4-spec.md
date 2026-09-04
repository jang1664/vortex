# GEMM Response RAM Default and WLOAD4 Verification Specification

Status: confirmed

## Goal

Make registered-read RAM the default storage for every parameterized GEMM
overlap response payload path.  Use `MXU_WLOAD_NUM=4` as the default
configuration for the associated verification and GEMM-node OOC helper flow.

## Scope

- Default `RESPONSE_DATA_RAM` to one in `VX_gemm_stream_dma_queue`, all local
  overlap DMA wrappers, and `VX_tmem_wide_read_switch`.
- Default the Input, Weight, Scale/Zero-point, and Weight-wide response RAM
  configuration macros to one in `VX_config.vh`.
- Keep explicit FF overrides available for A/B tests and debugging.
- Change focused overlap test defaults and defines from RAM-off/WLOAD8 to
  RAM-on/WLOAD4.  For Weight, use eight command beats so
  `MXU_WLOAD_NUM * W_LMEM_DMA_CMD_BEATS == MXU_ROW` remains true.
- Change `ci/run_gemm_node_ooc.sh` and its README to use the non-`_w8` WLOAD4
  config by default.
- Update the response-DPRAM task documents and helper config so current policy
  says RAM-on and WLOAD4, while clearly retaining historical WLOAD8 result
  labels for measurements that were actually collected with WLOAD8.

## Constraints

- Do not change the explicitly named WLOAD8 config; it remains an opt-in W8
  configuration.
- Do not remove the FF implementation or its explicit parameter override.
- Verify with VCS through `tools/verify_rtl.py` and use WLOAD4 defines.
- Run FPINT GEMM blackbox checks only through `ci/run_black.sh` in
  `xrt-vcs-sim` mode with the WLOAD4 config sourced.

## Acceptance

- Focused stream queue, Input, Weight, Scale/Zero-point, and wide-switch RAM
  tests pass using their new defaults and WLOAD4 where applicable.
- WLOAD4 FPINT GEMM xrt-vcs-sim passes for QDIR=0 and QDIR=1.
- No related script or current-policy document still makes WLOAD8 or RAM-off
  the default.
