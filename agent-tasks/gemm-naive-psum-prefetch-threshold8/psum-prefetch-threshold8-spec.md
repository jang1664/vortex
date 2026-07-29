# GEMM_NAIVE PSUM Prefetch Threshold 8 Experiment

## Goal

Test whether an accumulate command can safely begin once each PSUM FIFO has
eight entries, instead of waiting until both depth-16 FIFOs are almost full.

## Scope

- Modify only the GEMM_NAIVE input-start readiness policy in
  `hw/rtl/core/gemm/VX_gemm_unit.sv`.
- Preserve FIFO depths, PSUM eight-read same-set burst scheduling, bank-set
  drain ordering, write conflict handling, and all queue sizes.
- Run a fresh exact-config XRT-VCS blackbox test for M=256, K=256, N=256.

## Design decision

- Add per-bank accepted-response occupancy tracking suitable for the start
  threshold, or reuse existing reliable FIFO occupancy information if exposed.
- Permit input acceptance when each bank has at least eight PSUM entries.
- Short commands must still wait until all requested PSUM responses arrive.
- No change is accepted if it introduces PSUM underflow, mismatch, assertion,
  timeout, or deadlock.

## Baseline

- Exact config: `configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`
- Defines include `GEMM_NAIVE`, `NUM_THREADS=16`, `L1_MEM_PORTS=2`,
  `MXU_COL_TILE=32`.
- Current M256/K256/N256 result: PASS at 86,543 kernel cycles.

## Final agreed spec

Confirmed by the user's request on 2026-07-29.
