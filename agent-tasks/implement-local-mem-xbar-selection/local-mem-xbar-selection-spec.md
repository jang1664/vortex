# Local Memory Xbar Selection Specification

Status: confirmed

## Goal

Reduce local-memory routing congestion by making request and response fabrics independently selectable between the existing hierarchical crossbar and radix-2 Omega, while preserving the existing default configuration and public performance-counter meaning.

## Scope

- Add local-memory compile-time configuration in `hw/rtl/VX_config.vh`.
- Select request and response fabrics in `hw/rtl/mem/VX_local_mem.sv`.
- Preserve request-source identity and legacy final-bank collision semantics.
- Add behavioral coverage to `hw/unittest/local_mem_top` and make explicit unittest source lists Omega-compatible.
- Verify focused RTL behavior, then run the target naive GEMM through XRT/VCS.
- Compare full-chip QoR only after functional verification passes.

## Confirmed Design Decisions

- `LMEM_REQ_OMEGA_ENABLE` is a presence macro; absence selects HIER for requests.
- `LMEM_RSP_OMEGA_ENABLE` is a presence macro; absence selects HIER for responses.
- `LMEM_XBAR_MAX_FANOUT` is numeric, applies only to HIER branches, and defaults to platform `MAX_FANOUT`.
- Supported fanout values are `0` or powers of two greater than or equal to `2`.
- Invalid fanout must not instantiate a recursive HIER branch and must fail clearly in simulation and synthesis elaboration.
- `lmem_perf.bank_stalls` keeps the existing final-destination collision formula; Omega internal collisions remain unused.
- The focused primary matrix elaborates 32 request ports and 32 banks and exposes `bank_stalls` under `PERF_ENABLE`.
- Current `OUT_BUF` values and Omega per-stage buffering remain unchanged.
- Omega pipeline masks, bank-count changes, PE/SIMT changes, and dcache changes are outside scope.

## Verification Constraints

- Characterize HIER/HIER before changing production behavior.
- Focused verification is latency-insensitive and checks source/tag/data identity, no loss or duplication, hazards, backpressure, collision counts, and bounded progress.
- Blackbox verification sources `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh` and uses `ci/run_black.sh xrt-vcs-sim` from a configured build directory.
- Performance-counter comparisons enable the same PERF configuration for every candidate.
- PnR variants use isolated build directories and identical target, seed, clock, and directives; a small provisional improvement requires a second common-seed comparison before being called robust.

## Source Plan

- `docs/plans/2026-07-20-004-perf-local-memory-xbar-selection-plan.md`
