# Simplify GEMM_NAIVE PSUM Prefetch Gating

## Goal

Determine whether the PSUM startup fill requirement can be reduced without
redesigning the current no-backpressure GEMM compute datapath.

## Scope

- `hw/rtl/core/gemm/VX_gemm_unit.sv`
- Exact-config XRT-VCS blackbox verification for
  `fpint_gemm_ffn_hw_naive`

## Design Decisions

- Preserve the accumulate-command start-cycle initialization boundary.
- Release input after all requested PSUMs arrive or both per-bank FIFOs become
  almost full.
- Retain the total response counter for short commands.
- Preserve the existing per-bank credit tracking and LMEM arbitration.
- Treat any further watermark reduction as a separate token/reservation
  backpressure redesign, outside this simple gating experiment.

## Constraints and Assumptions

- Use `configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`.
- Verify `M=64, K=256, N=256` first with a deadlock timeout.
- Re-run `M=32/64, K=32, N=32` to guard output correctness.
- Preserve the previously fixed output LMEM stride and DMA edge bounds.

## Confirmed Specification

Immediate post-start streaming underflowed because the input pipeline outran
variable LMEM response latency. A 16-response watermark also underflowed: the
datapath accepted an approximately 30-row continuous burst while only two new
PSUM responses arrived. Restore the iteration-3 policy, already verified for
the large and small cases: wait for all requested rows or the approximately
30-response two-bank almost-full window. Reducing this lead requires explicit
consumer token/reservation backpressure and is outside the confirmed scope.
