# 02 — DSP48E2 mapping for GEMM PE tree

## Target

- `hw/rtl/core/gemm/VX_gemm_tree_v1.sv` (`u_mxu`, 162,925 LUTs)
- `hw/rtl/core/gemm/VX_pe_tree_new.sv` (each `tile_col[*].u_pe`,
  32 columns × ~4,081 LUTs = ~130 k)

## Problem

The PE tree performs MAC (multiply-accumulate). Today Vivado is inferring
the multipliers and adders in CLB fabric (LUT + CARRY8). Only 428 DSP48E2
are used in all of vortex_afu (**4.74 % of 9,024**). Massive headroom.

## Change

Direct the PE datapath into **DSP48E2 cascades**:

- Multiply + accumulate per PE → `DSP48E2` in A×B+C mode with `PCIN/PCOUT`
  cascade between adjacent PEs in the same column.
- For FP16 / INT8 accumulate, study whether two MACs can be packed per DSP
  (UG579 "DSP48E2 Packing") or whether the CVFPU integer pipe can be
  retargeted at the primitive level.
- Add `(* use_dsp = "yes" *)` hints on the MAC expressions, or instantiate
  `DSP48E2` primitives directly (safer for cascading).
- Pipeline the DSP path: `MREG`, `PREG`, and input A/B registers all
  enabled to hit kernel frequency.

## Expected savings

- 32 PE columns × hundreds of LUTs per PE saved via MAC offload.
  Rough estimate: **100 k – 140 k LUT** recovered on `u_mxu`.
- DSP cost: 32 cols × K rows × W wide → depends on BHF / accumulator
  width. Even 2,000 DSPs (22 % of device) leaves plenty of margin.

## Risks

- Cascaded DSPs lock placement into columns within a single SLR → SLR
  partitioning of the PE tree must match DSP column topology.
- DSP48E2 pre-adder or multiplier fixed widths (A = 30b, B = 18b, P = 48b)
  constrain data representations. Wider operands need splitting.
- Bit-exactness: rtlsim numeric path must match. Write a cosim unit test
  comparing fabric MAC vs DSP MAC on randomized vectors.

## Verification

- `hw/unittest/gemm_unit`, `hw/unittest/gemm_node_improve` regressions.
- Post-synth: `report_utilization` DSP count should jump by several
  hundred; `u_mxu` LUT should fall proportionally.
- Timing: run `report_design_analysis -timing` specifically for the
  DSP-heavy region.

## Dependencies / follow-ups

- Pairs well with **04_tile_size_scaling.md** — if tile size grows, fewer
  parallel PE columns are needed, so DSP count stays bounded.
