# MXU16 all-BRAM: 200 MHz exploration result

## Outcome

PnR and xclbin generation succeeded. Vitis reports an achieved kernel frequency
of **103.2 MHz**, automatically scaled down from the 200 MHz optimization target.
This improves the prior completed 100 MHz build's reported frequency by 3.2%;
it does not establish a global maximum or measured application speedup.

- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_200m.sh`.
- TH16/MXU16/HBM4/DMA4/TMEM8, all-BRAM, full-SLR.
- Placement `SSI_SpreadSLLs`; routing `AlternateCLBRouting`.
- Warning-only zero-Laguna policy retained; no RTL change or DCP retry.
- Started 2026-09-10 23:43:21 KST; finished 2026-09-11 03:41:54 KST.
- Elapsed 3h58m33s; exit code 0; xclbin approximately 64 MiB.
- Status checked hourly; monitoring ended at the 03:43 check.

## Final verification

| Metric | Result |
| --- | ---: |
| Requested kernel clock | 200 MHz |
| Vitis achieved kernel clock | 103.2 MHz |
| Final WNS / TNS | +0.003 ns / 0 ns |
| Setup-failing endpoints | 0 |
| Final WHS / THS | +0.004 ns / 0 ns |
| Hold-failing endpoints | 0 |
| Pulse-width-failing endpoints | 0 |
| Fully routed / routable nets | 843550 / 843550 |
| Routing errors | 0 |

The final archived timing report uses a **10 ns kernel reference period**,
not the original 5 ns target. Its kernel worst slack is +0.312 ns, while the
whole-design +0.003 ns belongs to a fixed platform clock. Vitis independently
reports the automatically calculated 103.2 MHz achieved clock. Neither result
proves 200 MHz closure or robustness across future RTL/implementation changes.
See `timing-analysis.md` for clock-specific attribution. No new simulation or hardware
execution was performed for this clock-only experiment.

All three exact FF-pair checks passed (post-init, post-opt, post-place). The log
contains no zero-Laguna placement warning in this attempt. The optional kernel
utilization-report copy failed with an ignored make error; the actual build
returned zero and the xclbin was generated.

## Evidence locations

Build root:
`build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_200m_spread_v1`

Output beneath that root:
`hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_200m_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`

- `bin/vortex_afu.xclbin`: generated binary.
- `bin/vortex_afu.xclbin.info:59`: requested clock; line60: achieved clock.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log:3205`: scaled frequency;
  line3206 explains automatic downscaling.
- Same implementation directory, `hw_bb_locked_timing_summary_postroute_physopted.rpt:166`:
  final timing summary after scaling.
- Same directory, `hw_bb_locked_route_status.rpt`: zero routing errors.
- Same directory, `runme.log:1351`, `:1643`, `:2255`: exact FF-pair check passes.
- Runner state/log and source manifest:
  `build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_200m_spread_v1/`.

The 300 MHz attempt failed with routing overlaps, whereas this 200 MHz attempt
legally routed and produced a 103.2 MHz binary. No further run was launched.
