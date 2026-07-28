# GEMM_NAIVE Final Write Queue Depth-4 Experiment

## Goal

Determine whether the GEMM_NAIVE final FP16 output queue can be reduced from
64 entries to 4 entries while preserving M256/K256/N256 correctness.

## Scope

- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`
- Change only `final_wr_queue` depth from 64 to 4.
- Fresh exact-config XRT-VCS blackbox test for M256/K256/N256.

## Design Decisions

- Preserve all PSUM FIFOs, PSUM write queue, LMEM arbitration, output layout,
  DMA bounds, and accumulator-bank scheduling.
- Do not add backpressure or change the producer in this experiment.
- Treat output mismatch, simulation fatal/assertion, timeout, or deadlock as a
  failed depth-4 result.

## Constraints and Assumptions

- Use `configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh`.
- Use a fresh configured build and confirm `GEMM_NAIVE`, `NUM_THREADS=16`,
  `L1_MEM_PORTS=2`, and `MXU_COL_TILE=32` in the VCS compile.
- The producer does not honor `final_lmem_bus_if.req_ready`; queue saturation
  can therefore lose an output pulse instead of applying backpressure.

## Confirmed Specification

Set the final-output elastic buffer size to exactly 4 and run the requested
M256/K256/N256 XRT-VCS test without any compensating RTL changes.
