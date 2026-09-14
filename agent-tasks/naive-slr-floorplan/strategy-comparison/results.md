# Naive PnR strategy comparison: both failed

Both fresh runs completed with route_design failure (wrapper exit code 2). No xclbin was generated. The user requested termination; both runs and the hourly monitor had already exited, so no signal was sent. No further runs are planned.

| Metric | Base | SLR strategy |
| --- | ---: | ---: |
| GEMM SLR pipeline / floorplan | Off / off | On / on |
| Place directive override | None | SSI_SpreadSLLs |
| Route directive override | None | AlternateCLBRouting |
| Post-placement WNS (ns) | -9.423 | -17.970 |
| Post-physical-opt WNS (ns), before routing | -8.880 | -17.923 |
| Post-physical-opt TNS (ns), before routing | -176582.791 | -342597.632 |
| Final remaining node overlaps | 64,373 | 180,973 |
| Maximum effective congestion level reported | 6 | 7 |
| Total wrapper elapsed | 6h 47m 41s | 9h 02m 42s |
| route_design elapsed | 3h 23m 26s | 4h 03m 41s |
| Finished (2026-09-14 KST) | 21:26:50 | 23:41:50 |
| Placed full-device CLB LUTs | 505353 | 517847 |
| Placed full-device CLB Registers | 521474 | 524912 |
| Placed full-device Block RAM Tile | 920 | 920 |
| Placed full-device DSPs | 656 | 656 |

## Assessment

Base had better placed timing, fewer unresolved routing overlaps, and a shorter run. The current SLR strategy did not improve physical feasibility in this experiment. Both fail the 100 MHz implementation objective; neither has valid final routed timing. Intermediate router WNS is not timing signoff, and no achievable frequency is inferred from these failed routes.

This compares two combined strategies, so it does not isolate pipeline, floorplan, and directive effects. Resource figures include the static platform and are placed figures. Both runs were concurrent; elapsed times are observed wall times, not controlled isolated runtime benchmarks.

The SLR strategy passed post-init, post-opt and actual post-place ownership/direct FF-pair checks. Its failure occurred in routing, not in those validation hooks. All recorded RTL/config/build source hashes remained unchanged throughout both runs.

## Reproduction and evidence

Common conditions: U55C 202210 platform, Vivado/Vitis 2025.1, 100 MHz, naive MXU16, LMEM1 MiB/16 ports/16 banks/all BRAM, FAST_MODE=0, no PERF/DEBUG, no congestion fail-fast, standard Vitis optimize=3. Base retains the common correctness hooks and clock uncertainty settings. Configurations and generated INIs were checked before and after launch.

- base: [implementation log](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_base_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log), [placed utilization](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_base_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/full_util_placed.rpt), [placed timing](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_base_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_placed.rpt), [failed-route checkpoint](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_base_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed_error.dcp).
- slr: [implementation log](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log), [placed utilization](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/full_util_placed.rpt), [placed timing](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_placed.rpt), [failed-route checkpoint](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_compare_20260914_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed_error.dcp).

Hourly snapshots, exact commands, exit codes and source provenance are under `runs/`.
