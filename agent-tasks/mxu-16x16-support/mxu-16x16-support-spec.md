# GEMM_IMPROVE MXU 16x16 Support Specification

Status: **confirmed**

Confirmed on: 2026-09-04

## Goal

Add a compile-time GEMM_IMPROVE MXU 16x16 profile while preserving the existing
MXU 32x32 profile. The first acceptance target is numerical correctness for the
five agreed `fpint_gemm_ffn_hw` cases under `xrt-vcs-sim`. Performance sign-off
is deferred.

## Scope

- Configuration propagation through RTL and generated C/C++ headers.
- IMPROVE tile-major input, weight, scale/zero-point, and output layouts.
- GEMM command sizing and address generation.
- A 16-bank, 32-byte-per-bank TMEM organization for MXU16.
- A dedicated 64-byte HBM-DMA to two 32-byte TMEM-bank adapter.
- 32-byte local DMA paths for MXU16 I/W/S/Z/O traffic.
- Unit tests for layout/FSM sizing, pair split/join behavior, routing, tags,
  byte enables, and backpressure.
- The five-case `ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw` gate.
- Compatibility closure for the retained MXU32 profile and secondary simx and
  legacy-kernel paths after Milestone A.

## Affected Areas

- `configs/` MXU32 and new MXU16 IMPROVE profiles.
- `hw/rtl/VX_config.vh` and generated configuration headers.
- `hw/rtl/core/gemm/` GEMM FSM, node, TMEM DMA controller, and local DMA.
- `hw/rtl/mem/` TMEM subsystem, switch, tensor bank, and new pair adapter.
- `tests/regression/fpint_gemm_ffn_hw/` host layout and functional driver.
- Standalone tile/detile regression kernels and fused layout producers.
- `hw/unittest/` GEMM FSM and TMEM routing/split-join tests.
- `sim/simx/gemm_node.*`, `kernel/src/fi_gemm.c`,
  `kernel/include/vx_tvm_gemm.h`, and `runtime/xrt/vortex.cpp` for final closure.

## Confirmed Design Decisions

1. MXU16 is selected at compile time with `MXU_ROW=16`, `MXU_COL=16`,
   `MXU_COL_TILE=16`, and `MXU_WLOAD_NUM=4`. Runtime-selectable and rectangular
   MXUs are outside this work.
2. The HBM DMA/AXI beat and descriptor contract remains 64 bytes.
3. MXU16 physical TMEM uses sixteen 32-byte banks of 32 KiB each. MXU32 keeps
   eight 64-byte banks of 64 KiB each, preserving total capacity and a depth of
   1024 lines in both profiles.
4. HBM-DMA channel `c` owns consecutive physical TMEM banks `2*c` and
   `2*c+1`. A 64-byte beat scatters low/high 32-byte halves to those banks in
   parallel and joins their responses in low/high order.
5. The pair adapter uses per-lane accepted bits on requests and shallow ordered
   response FIFOs with a matching-head join. It does not use associative reorder
   storage, lane-mask context, or the generic `VX_mem_bus_split` address mapping.
6. Aggregate request completion cannot be reported until both physical bank
   requests have handshaken. Both halves are active for accepted external GEMM
   DMA commands, while byte enables remain lane-specific.
7. MXU16 local I/W/S/Z/O DMA beats are 32 bytes. Partial sums remain on their
   existing 64-byte accumulator path.
8. Local reads that traverse the multi-bank TMEM switch retain tag-indexed
   response reordering because responses from different banks can cross request
   order. Output writes only drain acknowledgements.
9. The tile-major ordering and flat byte-address ABI remain unchanged. Layout
   formulas derive micro-tile sizes from MXU parameters. QCOL group counts use
   ceiling division, including `K=16, QBLK=32`.
10. Only external HBM `DMA_LD`/`DMA_ST` sizes are rounded to 64 bytes. Local
    I/W/S/Z/O command sizes stay logical (32 bytes in the MXU16 profile).
11. Rounded external transfers must fit their reserved TMEM/host slots, and
    every accepted external command must be nonzero and 64-byte integral.
12. XRT physical bank interleaving and its 64-byte granularity remain unchanged.

## Required Functional Matrix

All rows must run against the same MXU16 generated image, retain numerical
reference checking, avoid performance/benchmark-only flags, complete without
RTL assertions or hangs, and print `PASSED`.

| Case | M | N | K | WTRANS | QDIR |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2 | 32 | 128 | 0 | 0 |
| 2 | 1 | 16 | 16 | 1 | 0 |
| 3 | 3 | 17 | 17 | 0 | 1 |
| 4 | 31 | 48 | 80 | 1 | 1 |
| 5 | 129 | 129 | 129 | 0 | 0 |

All cases use `QBLK=32` and one repetition.

## Constraints and Non-goals

- Do not change the 64-byte HBM DMA, AXI, descriptor, or XRT transfer contract.
- Do not introduce a second MXU16-only tile-major ABI.
- Do not add new QBLK values as part of this milestone.
- Do not use cycle count, latency, throughput, area, or utilization as a
  functional PASS criterion.
- Do not claim repository-wide closure until retained simx and legacy-kernel
  paths either pass for MXU16 or reject the profile explicitly.

## Source of Truth

The detailed implementation phases, unit-test matrix, risk controls, and
acceptance criteria are in `mxu-16x16-support-plan.md`. If this specification
and the plan differ, resolve the difference explicitly before changing the
hardware contract.
