# 04 — GEMM tile size scaling

## Target

- `hw/rtl/core/gemm/VX_gemm_tree_v1.sv`, `VX_pe_tree_new.sv`,
  `VX_gemm_unit.sv`, associated parameters in `VX_config.vh` /
  `VX_gpu_pkg.sv`

## Problem

Current configuration uses **32 parallel PE tile columns**
(`tile_col[0..31].u_pe`) each ~4,081 LUT. Parallelism is expensive:
each added column replicates PE datapath, pipeline registers,
broadcast mux, and control overhead.

If the target throughput can be reached with fewer-but-larger tiles
(e.g. 16 columns, each doing 2× the work sequentially), the LUT/FF
count per compute-unit drops while the DSP utilization can stay the
same by folding two MACs into the same DSP over consecutive cycles.

## Change

Two directions, likely combined:

1. **Reduce column count**, grow inner tile width or temporal reuse.
   - e.g. 32 cols of width W → 16 cols of width W with 2× temporal
     accumulate. Halves the broadcast tree fanout and halves weight
     register replication.
2. **Deepen pipeline** on fewer cols.
   - Longer latency but same throughput; enables DSP OREG pipelining.

Both are parameter-level changes ideally controlled from
`VX_config.vh` (e.g. `GEMM_NUM_COLS`, `GEMM_TILE_DEPTH`).

## Expected savings

- PE tree LUT is ~162 k today. Halving cols could recover
  **50 k – 80 k LUT**, plus further savings in weight broadcast and
  operand steering.
- Impact on FF: equally large drop (fewer pipeline stages × fewer
  columns). The synthesis showed 470 k FFs total, ~half in the gemm
  subtree; halving cols cuts a meaningful chunk of those.

## Risks

- Throughput loss unless compensated by temporal reuse.
- Instruction-stream scheduler (`VX_gemm_dma_ctrl`, `VX_gemm_sync`,
  `VX_cmd_constructor`) may assume specific tile shapes — audit all
  four files referenced in `harness/rules/rtl-arch.md`.
- SW tiling in the kernel (`kernel/src/gemm.c`, `kernel/include/*`)
  must match.
- Verification matrix grows (new tile shapes × new shapes on all
  existing tests).

## Verification

- Regression: `hw/unittest/gemm_unit`, `gemm_node*`, `gemm_ctrl*`
- New micro-benchmarks for throughput at reduced col count
- End-to-end xrt hw_emu with representative GEMM shapes

## Dependencies / follow-ups

- Only make sense after DSP mapping (**02_dsp_pe_tree.md**) so that
  fewer columns still saturate compute.
- Revisit tensor-mem bank count (**07_tmem_bank_topology.md**) —
  bank fanout must match new column count.
