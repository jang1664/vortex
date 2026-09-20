# 16-slot Input scheduler results

The scheduler now uses the same Input slot count as the physical GEMM Input DMA queue. Both directed VCS tests and the `xrt-vcs-sim` numerical workloads pass.

## Cycle comparison

Config common to every row: improve GEMM, TH16, MXU16x16, WLOAD4, TMEM8, HBM4, `GEMM_SLR_PIPELINE`, QBLK32, K=512, N=512.

| M | Input slots | GEMM cycles | Core cycles | GEMM change | Core change |
|---:|---:|---:|---:|---:|---:|
| 4 | 8 | 8,188 | 13,997 | baseline | baseline |
| 4 | 16 | 8,174 | 13,922 | -14 (-0.17%) | -75 (-0.54%) |
| 256 | 8 | 306,946 | 312,726 | baseline | baseline |
| 256 | 16 | 274,171 | 279,951 | -32,775 (-10.68%) | -32,775 (-10.48%) |

The M=256 16-slot result is only 364 GEMM cycles and 377 core cycles above the previously measured non-SLR result (273,807 / 279,574). This confirms that the fixed eight-slot scheduler budget caused almost all of the SLR throughput loss.

## Verification evidence

- `microtile_readiness_scheduler` VCS unit test: PASS.
- Focused `_v2` `gemm_node_improve` VCS test (`M=4 N=32 K=64 QBLK=32`): PASS.
- M=4 and M=256 `ci/run_black.sh xrt-vcs-sim --perf 3`: PASS with numerical verification.
- Blackbox logs: `agent-tasks/latency_on_hw-refine/execution/input_slot16_scheduler/`.

## PnR

The fresh source-based 100 MHz PnR completed successfully on 2026-09-20:

- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2.sh`
- Postfix: `spread_slots16_v2r1`
- Runner result: return code 0, `status=complete`, `xclbin_exists=true`
- Requested/selected kernel frequency: 100 MHz
- Post-route timing: WNS +0.003 ns, TNS 0, WHS +0.005 ns, THS 0; all timing constraints met
- Route status: 841,586 routable nets fully routed, 0 routing errors
- XCLBIN: `build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin`
- XCLBIN size/SHA-256: 64,148,315 bytes / `4c33d07cfd486251fd39682dc090066fcbff2e37643be3e1a3d0c9b8b5b95af0`
- Final timing report: `build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt`
- Route report: `build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt`
- State: `build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1/state.json`
- Log: `build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_v2_spread_slots16_v2r1/build.log`

The build emitted platform and methodology warnings, but route, DRC, timing signoff, bitstream generation, and XCLBIN packaging all completed with zero errors. Two optional kernel-utilization report copies were absent and ignored by the existing Makefile; the routed timing and full-utilization reports were produced.

An earlier launch with postfix `spread_slots16_v2` was stopped during source preprocessing because its systemd PATH omitted Verilator. Its evidence was retained and marked `aborted_invalid_environment`; no result from that launch is used.
