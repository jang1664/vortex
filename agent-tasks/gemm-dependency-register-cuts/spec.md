# GEMM dependency-release register-cut experiment

Status: confirmed; scope narrowed by the user's umbrella-switch request.

## Goal

The initial audit inventories GEMM same-cycle release-to-issue paths. The user's
subsequent decision is to make the two already-implemented optional cuts,
`GEMM_TIMING_REG_ACC_FREE` and `GEMM_TIMING_REG_DMA_DEPS`, inherit
`GEMM_TIMING_CUTS` and compare the complete umbrella OFF versus ON using
xrt-vcs-sim with `--perf 3`.

## Scope and decisions

- Primary configuration: `configs/improve_th32_tcol32_m32_t4_bigmem.sh`, matching
  the preceding routed critical path; retain SLR transport and WLOAD_NUM=4.
- Audit GEMM controller, node, compute, local DMA and TMEM DMA scheduling paths.
  Document already-registered paths and ordinary transport ready chains separately.
- Change only the two defaults and associated documentation; retain explicit
  per-cut overrides. New Z-release, stream-capacity and TMEM-chain cuts remain
  audit proposals, not authorized implementation in the narrowed experiment.
- Preserve functional results, ordered notifications and ready/valid contracts.
  Do not register a pulse blindly or accept an unsafe stale resource grant.
- Preserve the current dirty worktree and all previous PnR artifacts.
- Measure `GEMM_TIMING_CUTS=0` versus `GEMM_TIMING_CUTS=1`, with no individual
  overrides masking the new umbrella defaults. This measures the complete
  control/transport profile, not the isolated cost of its two new defaults.
- Use GEMM hardware performance-counter cycles, not host/kernel elapsed cycles.
  Record exact metric semantics, test shape, flags, source identity and raw logs.
- No synthesis, OOC, PnR, commits or production config policy changes in this task.
  Simulation proves function and cycle cost, not physical timing closure.

## Verification

- Source the exact config and configure fresh build directories before tests.
- Use `ci/run_black.sh xrt-vcs-sim ... --perf 3` with the FPINT GEMM app.
- Cover both quantization directions, both weight-transpose modes, short and
  multi-tile overlapping workloads. Compare identical inputs and repeat selected
  cases to distinguish deterministic GEMM cost from measurement variation.
- Run focused VCS controller checks through `tools/verify_rtl.py` where applicable.
- Report every audited path with RTL line anchors, cut location and tested group.
- Report any unsupported or untested edge explicitly; do not claim exhaustive
  dynamic coverage or a timing improvement without synthesis evidence.
