# GEMM Unit V2 Consecutive Accumulation Forwarding Specification

Status: confirmed

## Goal

Support GEMV traffic where two or more consecutive input packets accumulate
into the same PSUM address. The newer packet must consume the immediately
preceding packet's writeback value without waiting for ACC SRAM write followed
by read.

Also repair the `gemm_node_improve` unittest's partial-K weight stimulus so
`K < DMA_KT` cases actually initialize weight DRAM.

## Scope

- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- `hw/unittest/gemm_unit_v2/tb_VX_gemm_unit_v2.sv`
- `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`
- V2 RTL documentation and task status

V1 RTL, the naive node, top simulation, blackbox tests, and synthesis are out
of scope.

## Design Decisions

1. At input admission, mark a packet for forwarding when it accumulates from
   the same address written by the valid packet admitted exactly one cycle
   earlier.
2. Pipeline the forwarding bit with the packet sideband.
3. Suppress the forwarded packet's ACC SRAM read request. This prevents stale
   reads and same-bank nominal/early request collisions for repeated addresses.
4. At the accumulator input, select the immediately preceding packet's aligned
   writeback result instead of SRAM/early-hold data.
5. Forward both accumulation and load writeback results when the preceding
   packet has `acc_wr_en=1`; require the preceding writeback to be valid.
6. Preserve the existing K-lookback early-read scheduler for packets that are
   not forwarded.
7. Permit either strict `+GEMM_PSUM_DATA_SIZE` address progression or a same-
   address immediate forwarding dependency in simulation assertions.

## Required Verification

- Two consecutive same-address accumulation packets produce the cumulative
  result and the second packet issues no ACC SRAM read.
- Exact write latency, address, completion, and no-backpressure scoreboards
  remain green.
- Existing nominal/early/bubble/random/nonzero V2 tests remain green.
- `gemm_node_improve` M32/N32/K32 passes after partial-K weight stimulus repair.
- Existing V1 unittest remains unchanged and green if rerun is needed.

## Partial-K Testbench Fix

`write_dram_tiled_weight` must use ceiling division for DMA K tiles and only
emit the valid number of MXU K microtiles in the final partial DMA tile. It
must not index `weight_mat` beyond `test_k`.
