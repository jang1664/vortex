# FPINT Naive/Improve RTL Unification

Status: confirmed

## Goal

Build both FPINT GEMM memory architectures from the `fpint` branch. Define
`GEMM_NAIVE` to select the LMEM/shared-DMA backend; leave it undefined to
select the current TMEM/eight-channel-AXI backend.

## Scope

- Add the `GEMM_NAIVE` configuration contract to every naive GEMM config.
- Preserve the current `VX_gemm_unit.sv` source for both architectures.
- Import the naive node, controller, FSM, synchronization, and shared-DMA
  command path from `origin/fpint_naive` commit `ffb5aecb3` under distinct
  `_naive` module/interface names.
- Reuse the current CPU DMA and `VX_lmem_dma_misal` implementations.
- Select the LMEM and GEMM-node topology in `VX_core` and `VX_mem_unit`.
- Update the GEMM unit/node unittest build manifests for configuration-aware
  VCS builds.
- Verify both RTL modes with unittests and focused `xrt-vcs-sim` blackbox runs.

## Design Decisions

- `GEMM_NAIVE` is the only architecture selector. The current local DMA skips
  its completion sync state when this macro is defined; no extra parameter is
  added.
- Weight bandwidth remains architecture-specific. Naive elaborates
  `MXU_WLOAD_NUM=1` (16 bytes, one weight row per GEMM-unit request); improve
  retains `MXU_WLOAD_NUM=4` (64 bytes, four rows per request).
- No 16-byte-to-64-byte weight bridge is added.
- The current optimized accumulator/read-prefetch logic in `VX_gemm_unit.sv`
  is shared by both builds.
- Naive functional compatibility is required; bit-identical synthesis against
  `origin/fpint_naive` is not required.
- The existing applications remain separate:
  `fpint_gemm_ffn_hw` and `fpint_gemm_ffn_hw_naive`.

## Constraints and Assumptions

- Improve TMEM/AXI behavior and local-DMA completion synchronization must not
  change when `GEMM_NAIVE` is undefined.
- Naive keeps its 16-byte weight transactions and LMEM/shared-DMA topology.
- Generated build files must be refreshed after source Makefile changes.
- RTL tests run from configured build directories with `/usr/bin/gcc` and
  `/usr/bin/g++` for host compilation.
- Blackbox testing uses `ci/run_black.sh xrt-vcs-sim`; it never calls
  `blackbox.sh` directly or runs with empty `CONFIGS`.
- Hardware and `hw_emu` validation are outside this task.

## Confirmed Verification

1. Run `gemm_unit` in improve and naive configurations.
2. Run `gemm_node_improve` and the adapted naive `gemm_node` tests with
   WTRANS/QDIR and K-accumulation coverage.
3. Run focused `xrt-vcs-sim` cases for both FPINT GEMM applications, starting
   with 32x32x32 and extending through WTRANS, QDIR, and K=128 cases.

