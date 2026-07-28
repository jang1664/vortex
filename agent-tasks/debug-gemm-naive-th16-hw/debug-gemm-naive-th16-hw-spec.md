# GEMM_NAIVE th16 FPGA Correctness Debug Specification

## Goal

Debug the `GEMM_NAIVE` RTL path used by
`fpint_gemm_ffn_hw_naive` with
`configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`.
The immediate correctness targets are:

- `-m 32 -k 32 -n 32`
- `-m 64 -k 32 -n 32`

The larger observed hang at `-m 64 -k 256 -n 256` remains in scope after
the two small cases pass.

## Scope

- The `GEMM_NAIVE` node, controller, GEMM unit, local-memory, cache, DMA, and
  response-routing RTL exercised by the target configuration.
- Focused RTL unit or integration regressions needed to reproduce the bug.
- XRT-VCS integration runs with the exact target configuration.
- Real-FPGA runs using the existing configured hardware image when available.

## Constraints and Assumptions

- Preserve unrelated user changes in the dirty worktree.
- Use a configured and isolated build directory for authoritative VCS artifacts.
- Use `ci/run_black.sh` for blackbox tests and source the exact configuration
  before every run.
- Do not treat a stale VCS image or a differently defined configuration as
  verification evidence.
- Do not weaken the requested shapes or substitute a software-only backend.
- Existing PSUM ordering fixes and the current source tree are the baseline.

## Design Decisions

- Diagnose with log evidence first; add targeted guarded RTL traces only when
  existing traces are insufficient.
- Prefer a generic correctness fix at the violated ordering or routing contract
  over a shape-specific workaround.
- Keep the larger `M=64,K=256,N=256` hang as a required follow-up after the
  small-case correctness gate.

## Confirmed Specification

The user's report explicitly identifies the configuration, workload, failing
shapes, and requested priority. This specification is therefore confirmed for
implementation and verification.
