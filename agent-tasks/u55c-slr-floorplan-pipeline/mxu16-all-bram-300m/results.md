# MXU16 all-BRAM 300MHz attempt

Result: **failed at post-place SLR validation**, before routing. No xclbin.
Started2026-09-10 11:21:47KST; finished14:39:54, runner exit2.
Final monitoring check14:51:47. No automatic retry, DCP restart or hook bypass.

Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_300m.sh`.
Only the requested clock differs from the successful100MHz MXU16 all-BRAM
profile. Geometry, memory selections, full-SLR pipeline/floorplan,
SSI_SpreadSLLs and AlternateCLBRouting remain unchanged. Generated INI contains
`kernel_frequency=0:300`; runner metadata records300MHz. No RTL changes.

## Fatal condition

The post-place hook reported:

```text
u_VX_gemm_unit_v2/u_compute_core/mxu_output: no actual Laguna TX/RX pairs
```

`post_place_slr_links.tsv` contains625 direct pairs in this group. All625 TX
registers occupy Laguna sites; none of the RX registers occupies a Laguna site,
so the actual Laguna pair count is zero. Logical SLR ownership remains2->1.
The marked-group validation passed, but physical pair validation failed.
Post-init and post-opt pair checks had passed before placement.

RTL boundaries are `g_slr_mxu_output_tx` and `g_slr_mxu_output_rx` in
[VX_gemm_compute_core.sv:1617](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1617)
and [line1626](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv:1626).
The failure establishes a physical mapping mismatch, not a numerical RTL bug.
Why the placer selected general SLICE RX registers requires further physical
analysis; this attempt does not establish the underlying placer decision.

## Timing, independently of the fatal hook

Placed timing at3.333ns:

| Metric | Value |
| --- | ---: |
| WNS | -8.142ns |
| TNS | -425732.656ns |
| Setup failing endpoints | 216,853 |
| WHS | -0.223ns |
| Hold failing endpoints | 7,314 |

Worst placed path:

```text
u_compute_core/int2fp_result_count_reg[0]
  -> u_tmem_subsystem/u_ldma_input/u_stream_queue/
     g_response_data_ram.response_payload_ram/.../ram_reg_2/ENARDEN
```

Data-path delay10.532ns: logic2.472ns and estimated routing8.060ns,24 logic
levels. These are **placed, not final routed** results. Bypassing the hook would
not itself fix this timing violation. No achieved frequency can be reported
because routing and xclbin generation did not complete.

## Evidence

Repository-relative output directory:

```text
build/pnr/build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/
```

Under `_x/link/vivado/vpl/prj/prj.runs/impl_1/`:

- `runme.log:2264`: first fatal SLR validation condition.
- `post_place_slr_links.tsv:283`: first mxu_output pair row.
- `hw_bb_locked_timing_summary_placed.rpt:166`: timing summary.
- Same timing report, line2024: worst path.
- `post_place_slr_failed.dcp`: diagnostic checkpoint created automatically by hook;
  not loaded or used for retry in this task.

Runner artifacts:
`build/pnr/build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v1/`.
Monitor history:
`build/pnr/build_timing_cuts_pnr_artifacts/mxu16_all_bram_300m_monitor/history.jsonl`.
