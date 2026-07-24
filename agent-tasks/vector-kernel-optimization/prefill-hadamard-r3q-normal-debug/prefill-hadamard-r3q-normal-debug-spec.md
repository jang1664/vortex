# Prefill Hadamard R3-Q Normal Correctness Debug

## Goal

Identify and fix the root cause of the nondeterministic correctness failures
reported for the standalone Prefill Hadamard R3-Q workload, then re-run the
failing hardware test and appropriate regression coverage.

## Scope

- `tests/regression/hadamard/`
- Shared kernel launch, memory, or hardware logic only if reproduction proves
  that the defect is outside the Hadamard regression app
- `docs/kernel/optimizations/c4_normal_vs_layout_fused_all_cases.md`
- This task's `STATUS.yaml`

## Design Decisions

- Reproduce the exact C4 command from the report before selecting a fix.
- Preserve the standalone Hadamard numerical definition and FP16 tolerance.
- Treat varying mismatch locations as evidence of a synchronization, memory
  visibility, address-boundary, or launch-scheduling defect until logs prove
  otherwise.
- Compare the failing `rows=32768, dim=128, K=1` shape with smaller passing
  shapes and boundary-adjacent shapes to isolate size-dependent behavior.
- Use the configured build and `ci/run_black.sh`; do not invoke an unconfigured
  blackbox flow.

## Constraints and Assumptions

- Real C4 hardware is authoritative for the originally reported failure.
- `xrt-vcs-sim` is used when RTL-level reproduction or trace evidence is
  required.
- Existing unrelated worktree changes must be preserved.
- A passing single run is insufficient for a previously nondeterministic
  failure; repeat the exact failing case after the fix.

## Confirmed Specification

The user explicitly requested root-cause diagnosis, a fix, and re-testing of
the `Prefill Hadamard R3-Q Normal` correctness failure. This specification is
confirmed for implementation and verification.
