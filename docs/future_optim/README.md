# Future Optimization Backlog — fpint_improve on Alveo U55C

Baseline: the first hardware synthesis of `fpint_improve` for
`xilinx_u55c_gen3x16_xdma_3_202210_1` failed with
**LUT 104.50 %** (1,197,809 / 1,146,240) in `impl_1/report_qor_assessment`.
vortex_afu itself consumed 1,142,237 LUTs (87.62 % of device) and
`gemm_node` alone took 993,517 of those (86.9 % of vortex_afu).

Reference reports:
- `build/hw/syn/xilinx/xrt/core1_fpint_improve_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/reports/link/imp/impl_1_qor_assessment_pre_opt_design.rpt`
- `build/.../_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt`
- `docs/sram_doc.md` — URAM/BRAM constraint reference

## Inventory of items

Rough rank by expected LUT recovery per unit of engineering effort.
Each linked file contains the targeted files, the change, expected savings,
risks, and any prior analysis notes.

| # | Optimization                                   | Est. LUTs recovered | Effort | Status        |
|---|------------------------------------------------|---------------------|--------|---------------|
| 1 | [URAM for tensor_mem_bank](01_uram_tensor_mem.md) | ~280 k              | S      | in progress   |
| 2 | [DSP48E2 mapping for GEMM PE tree](02_dsp_pe_tree.md) | ~100 k +            | M      | backlog       |
| 3 | [weight_regs on BRAM/URAM](03_weight_regs_mem.md) | ~30 k               | M      | backlog       |
| 4 | [GEMM tile size scaling](04_tile_size_scaling.md) | 50 k – 100 k        | M-L    | backlog       |
| 5 | [DMA engine slimming](05_dma_engine_slim.md)   | 100 k – 200 k       | M      | backlog       |
| 6 | [Execute pipeline trim](06_execute_pipeline_trim.md) | ~15 k               | S      | backlog       |
| 7 | [Tensor-mem bank count / topology](07_tmem_bank_topology.md) | 50 k – 150 k        | L      | research      |
| 8 | [URAM-ize other LUTRAM consumers](08_uram_other_consumers.md) | TBD                 | S      | research      |

Effort key: **S** = single-file / few-hundred-line change.
**M** = multiple modules, architectural review, parameter audit.
**L** = new architecture, verification-intensive.

## Constraints that apply to every item
- Target device: `xcu55c-fsvh2892-2L-e`, 3 SLRs, 1,304 k LUTs, 2,016 BRAM36,
  960 URAM288, 9,024 DSP48E2.
- Current slack: LUTs over by ~52 k (104.50 %), BRAM 70 % (1,405 / 2,016),
  URAM 6.25 % (60 / 960), DSP 4.74 % (428 / 9,024).
- Timing WNS = −1.107 ns in the failing run. Any optimization that
  lengthens a critical path should pre-stage timing checks.
- All RTL changes must keep bit-exact compatibility with simx / rtlsim
  unless accompanied by a corresponding behavioral model change.

## Performance architecture notes

- [GEMM sync output HOL blocking](gemm_sync_output_hol_blocking.md): output
  `WAIT RID_O` can block the single parent command stream and prevent
  independent compute/preload commands from reaching child queues.
