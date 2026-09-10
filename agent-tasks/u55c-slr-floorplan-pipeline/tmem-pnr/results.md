# URAM / BRAM PnR results

Completed and checked on 2026-09-09, with 30-minute status updates.

## Outcome

Both fresh source-based builds completed with exit code 0 and generated xclbin
files. Both route-status reports show zero routing errors. However, **neither
meets the requested 100 MHz setup timing**. The xclbin information reports achieved
kernel-00 frequencies of 88.4 MHz (URAM) and 95.4 MHz (BRAM).

| Metric | URAM TMEM | BRAM TMEM |
| --- | ---: | ---: |
| Finished (KST) | 06:10:00 | 06:20:33 |
| Total elapsed, including configure | 8h 15m 11s | 8h 25m 44s |
| Build exit code | 0 | 0 |
| Routing errors | 0 | 0 |
| Routable / fully routed nets | 1,381,470 / 1,381,470 | 1,381,668 / 1,381,668 |
| Requested frequency | 100 MHz | 100 MHz |
| Achieved frequency, xclbin.info | 88.4 MHz | 95.4 MHz |
| Post-route-physopt WNS at 10 ns | -1.304 ns | -0.472 ns |
| TNS at 10 ns | -2456.432 ns | -295.579 ns |
| Setup failing endpoints | 8,363 | 1,889 |
| WHS | +0.004 ns | +0.001 ns |
| Hold failing endpoints / THS | 0 / 0 ns | 0 / 0 ns |

The relevant xclbin system clock is `ulp_ucs_aclk_kernel_00`, not the separate
500 MHz kernel-01 clock. Timing numbers above come from the 10 ns reports; they
are not a claim of new timing analysis at the lower achieved frequencies.

BRAM improved WNS by 0.832 ns in this pair of runs. Routing succeeded in both,
so the remaining blocker to the 100 MHz target is setup timing, not an unresolved
routing overlap. This is one run per configuration, not proof of robustness
across future RTL revisions.

## Binary and report paths

| Memory | Binary | Clock information |
| --- | --- | --- |
| URAM | [vortex_afu.xclbin](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin) | [xclbin.info](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin.info:54) |
| BRAM | [vortex_afu.xclbin](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin) | [xclbin.info](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin.info:54) |

- URAM: [post-route-physopt timing](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:160), [route status](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt).
- BRAM: [post-route-physopt timing](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:160), [route status](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt).

## Remaining worst timing path

Both variants' worst setup paths are in the **core operand collector**, not the
TMEM RAM itself:

`issue/.../opc_unit/pipe_reg2/.../pipe_reg[0][193]`
to `opc_unit/out_buf/g_eb2.stream_buffer/...`.

The corresponding RTL instances are
[VX_opc_unit.sv:208](../../../hw/rtl/core/VX_opc_unit.sv:208) (`pipe_reg2`) and
[VX_opc_unit.sv:306](../../../hw/rtl/core/VX_opc_unit.sv:306) (`out_buf`).
The exact meaning of optimized bit 193 has not been decoded in this monitoring task.

| Variant | Destination register | Data path delay | Logic / routing | Logic levels |
| --- | --- | ---: | --- | ---: |
| URAM | `buffer_r_reg[3880]` | 10.681 ns | 0.227 / 10.454 ns | 1, LUT4 |
| BRAM | `data_out_r_reg[1125]` | 9.845 ns | 0.225 / 9.620 ns | 1, LUT6 |

These are approximately 98% routing-delay paths. This identifies the next timing
investigation target; it does not establish a particular physical root cause.
See [URAM path](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:2033)
and [BRAM path](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:2013).

## Memory mapping and resource tradeoff

The hierarchy reports confirm the intended change for all eight TMEM arrays:

- URAM variant: 8 URAM primitives per array, **64 URAM total**.
- BRAM variant: 16 RAMB36 primitives per array, **128 RAMB36 total**.

Whole-design **placed** utilization (not a fresh post-physopt resource audit):

| Resource | URAM variant | BRAM variant | BRAM minus URAM |
| --- | ---: | ---: | ---: |
| CLB LUTs | 762,858 | 762,610 | -248 |
| CLB registers | 643,547 | 643,586 | +39 |
| BRAM tiles | 751.5 | 879.5 | +128 |
| URAM | 156 | 92 | -64 |
| DSP | 2,265 | 2,265 | 0 |

BRAM tile use in SLR0 increased from 369/672 (54.91%) to 497/672 (73.96%).
ACC/core-local-memory mapping was not changed.

Sources: [URAM placed utilization](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_utilization_placed.rpt),
[BRAM placed utilization](/home/jaeyongjang/project.local/vortex_fpint/build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_utilization_placed.rpt),
and the `g_bank[0..7].u_bank` rows starting at line 5254 of each
`hier_utilization.rpt`.

## Flow checks and caveats

- Run logs confirm `place_design -directive SSI_SpreadSLLs -retiming` and
  `route_design -directive AlternateCLBRouting`.
- Post-init, post-opt, and post-place SLR marked-group / FF-pair validation passed.
- Both Makefiles emitted an ignored optional report-copy warning for the absent
  `impl_1_kernel_util_routed.rpt`. It did not prevent binary generation or change
  the exit status; actual implementation reports listed above exist.
- No automatic retries, DCP reimplementation, RTL edits, or directive changes
  occurred during these runs. No new hardware execution or xrt-vcs-sim was run.
- The periodic monitor stopped when both runs became terminal at the 06:25 check.
