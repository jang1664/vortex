# C4 unified MMIO PnR result

- Source commit: `2d6998e4e9b5f956eda667f2b61244e951159ded`.
- Entry point: existing `build/hw/syn/xilinx/xrt/run_hw.sh`.
- Config: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion`.
- Postfix: `20261030_unified_mmio_r1`.
- Started: 2026-10-30T15:10:50.190812+09:00.
- Completion observed: 2026-10-30 20:33:54 KST; exit code **0**.
- Fresh synthesis, placement, routing and bitstream generation completed.
- Target and packaged DATA_CLK frequency: **100 MHz**. No downward frequency scaling.
- Vitis frequency estimate: 102.4 MHz; compiler retained requested 100 MHz.
- Final routed kernel-clock setup WNS: **+0.236 ns**, TNS **0**, failing endpoints **0**.
- Final routed kernel-clock hold WHS: **+0.003 ns**, THS **0**, failing endpoints **0**.
- Full-design setup WNS **+0.003 ns**, hold WHS **+0.003 ns**; all user specified timing constraints met.
- Xclbin size: 70204371 bytes; SHA256 `c330b5270631894e5462168aee7281e0d38bcfa1914cd5223d498b2977f239ff`.
- Two optional report-copy commands found no `impl_1_kernel_util_synthed.rpt` / `impl_1_kernel_util_routed.rpt`; make ignored these copy failures. Main timing, utilization, hierarchy reports and xclbin exist.
- This report records implementation validation. Subsequent FPGA testing passed
  [nine functionality cases](../../hardware/20261031_unified_mmio_r1/RESULTS.md);
  [the matched attention comparison](../../hardware/20261031_attention_comparison/RESULTS.md)
  records the separate performance result.

Artifacts:

- [Xclbin](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_20261030_unified_mmio_r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin)
- [Xclbin information](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_20261030_unified_mmio_r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin.info)
- [Final routed timing](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_20261030_unified_mmio_r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/impl_1_hw_bb_locked_timing_summary_routed.rpt)
- [Full routed utilization](/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_20261030_unified_mmio_r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/impl_1_full_util_routed.rpt)
- [Launch log](launch.log)
- [Hourly monitor](hourly-monitor.jsonl)

Monitoring completed when the build exited; no hosted recurring automation was created.
