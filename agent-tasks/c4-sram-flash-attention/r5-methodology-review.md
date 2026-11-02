# R5 post-init methodology review

R5's completed `post_init_methodology.rpt` (2026-10-24 05:14:25, Vivado 2025.1, **Synthesized** design state) contains 116 checks. All 116 details match R4 after replacing only the absolute build-directory prefix. R4's additional `TIMING-23#1` combinational-loop warning is absent in R5. The historical unchanged-rev8 post-init report also matches all 116 R5 details after that same path normalization. This is bounded post-init evidence, not a waiver or final physical/timing acceptance.

Immutable copies, original paths, SHA256, per-rule counts and exact comparison results are in [logs/r5_methodology_review/receipt.json](logs/r5_methodology_review/receipt.json). Full detail blocks and original reports are alongside it; [constraint_sources.json](logs/r5_methodology_review/constraint_sources.json) records the referenced XDC hashes and lines. No Vivado invocation, source/constraint change or live-process action was performed.

## Findings that must remain visible

| Rule | R5 count | Exact object/constraint and scope |
|---|---:|---|
| TIMING-1, Critical | 1 | Platform UCS kernel-00 clock wizard `.../ulp_ucs/inst/aclk_kernel_00_hierarchy/clkwiz_aclk_kernel_00/inst/CLK_CORE_DRP_I/clk_inst/mmcme4_adv_inst/CLKOUT0`: `clk_kernel_00_unbuffered_net` is constrained to `10 {0 5}` ns while CMB settings imply `3.333 {0 1.667}`. This platform-origin finding directly matters to the accelerator clock contract; 100 MHz cannot be certified by the config string alone. |
| TIMING-7, Critical | 1 | Platform `io_clk_pcie_00_clk_p` and `dma_ip_axi_aclk_1` are timed as related without a common node. |
| TIMING-14, Critical | 1 | Platform debug LUT `level0_i/blp/blp_i/ss_cmp/inst/mgmt_debug_bridge/inst/bsip/inst/USE_SOFTBSCAN.U_BSCAN_TAP/U_BASETAP/update_INST_0` lies on a clock tree. Report explicitly requests recheck after opt. |
| TIMING-54, Critical | 6 | Platform scoped clock groups: PCIe ↔ GT intclk, positions 216/215; PCIe ↔ pipe_clk_1, positions 219/220; MDM DRCK and UPDATE/debug groups, positions 25/24. Their scope can affect paths outside the IP; inherited origin is not proof the exception coverage is safe. |
| TIMING-16, Warning | 2 | `ulp_ucs/.../clock_throttling_aclk_kernel_01/U0/Gate_Fast_d1_reg/C` → `GC.FCLK/CE`: **−1.107 ns**, kernel-01 clock. PCIe `.../pcie_4_c_e4_inst/CORECLK` → DMA `.../chain_cfg_phy_link_down/with_ff_chain.ff_chain_gen[0].sync_rst.ff_chain_reg[1][0]/D`: **−1.607 ns**, GTYE4_CHANNEL_TXOUTCLK[3]_7 → dma_ip_axi_aclk_1. Both named paths are platform paths, not GEMM/TMEM/LMEM endpoints. These are post-init estimates, not final routed slack. |
| TIMING-9 / TIMING-10, Warning | 1 / 1 | Unknown CDC logic / missing ASYNC_REG. These summary items contain **no endpoints**. Ownership is unlocalized; neither platform-only nor task-owned can be inferred from this report. |
| TIMING-18 / TIMING-24 / TIMING-47, Warning | 1 / 1 / 7 | PCIe PERST missing input delay; MDM DRCK clock-group position 25 overrides max-delay position 222; synchronous debug/peripheral/DMA clocks masked by group positions 24/25. Platform names, with unresolved effective exception coverage. |
| LUTAR-1 / NTCN-1, Warning | 20 / 16 | Listed reset/clock-delay objects are platform PCIe, PLP, management/debug paths. No explicit `level0_i/ulp/vortex_afu_1` object occurs in any R5 detail. This does not localize endpointless CDC or every path affected by a broad constraint. |
| XDCB-5 / XDCC-1 / XDCC-7, Warning | 1 / 2 / 2 | Platform `impl.xdc:91` hierarchical IRQ false-path query; duplicate generated clocks in `axi_jtag.xdc:8` (divide 8) and `bsip.xdc:8` (divide 1). XDCB-6 advisories also reference platform `impl.xdc:91–92` IRQ/HBM-reset exceptions. |

There are nine Critical Warning checks in total (1+1+1+6). The remaining 53 advisories are CLKC-3/13/40/56 (30/1/1/2), RTGT-1 (17), XDCB-6 (2); their exact details/counts are preserved rather than omitted from acceptance evidence.

## Task-owned change and historical comparison

R4 `TIMING-23#1` disabled the I2→O timing arc of:

```
level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/execute/lsu_unit/g_blocks[0].lsu_slice/mem_scheduler/req_queue/g_eb2.stream_buffer/g_buffer.g_out_reg.data_out_r[1714]_i_3
```

That matches the task's already established publication/ready cycle. Its absence after the deferred-PUBLISH repair is useful early evidence. The separate optimized-DCP LUTLP/loop probe and final routed DRC remain mandatory; this text comparison cannot replace them.

The old rev8 report is from `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_cc4901d20c/_x/link/vivado/vpl/prj/prj.runs/impl_1/`. Its post-init report (Oct 10 01:07:11) has the same 116 checks. Its **Fully Routed** `hw_bb_locked_methodology_drc_routed.rpt` (Oct 10 04:02:28) still has all nine critical findings and 115 total checks: kernel-01's −1.107 ns TIMING-16 item disappears, while the PCIe→DMA −1.607 ns item remains. That is historical persistence evidence only, not proof of harmlessness or permission to suppress warnings in R5.

## Final R5 acceptance follow-up

1. Preserve actual optimized and routed methodology/DRC reports with checkpoint/source hashes. Require no task-owned LUTLP/TIMING-23 combinational loop, no new unexplained task-owned warning/exception, and explicitly compare any changed object/constraint against this baseline. Root's optimized loop probe remains separate.
2. Verify the final kernel clock waveform, generated-clock relation and actual packaged/loaded achieved clock agree. Resolve or explicitly document the UCS 10 ns versus 3.333 ns discrepancy using the actual clock implementation/configuration; do not infer resolution from an unchanged report or nominal frequency.
3. Read final routed timing summary and detailed worst setup/hold/recovery/removal paths, clock-interaction/exception coverage, unconstrained endpoints and final route status. Confirm task paths meet the accepted clock and retained cross-SLR constraints. Track the two named platform setup paths separately from task timing; an old platform violation is not a new GEMM failure, but must stay disclosed in whole-platform acceptance.
4. Use available final CDC detail to localize TIMING-9/10. If absent, retain the unresolved status and request only targeted CDC/exception review; do not invent endpoints or treat generic text as a passed CDC audit. Verify broad platform clock groups/IRQ/HBM-reset exceptions do not silently mask task paths.
5. Carry forward unchanged vendor-platform findings with explicit ownership and disposition in the final physical-acceptance receipt. This task does not authorize wholesale platform remediation or warning waivers. Any remaining unresolved item limits the acceptance claim; keep it separate from the completed task-owned loop repair and SRAM numerical/traffic proofs.
