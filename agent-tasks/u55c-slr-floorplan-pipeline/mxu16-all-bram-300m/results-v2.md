# MXU16 all-BRAM: 300 MHz frequency-exploration retry

## Outcome

The warning-only Laguna policy worked, but routing failed. There is no xclbin
and no measured achieved kernel frequency for this attempt. This is not simply
a failure to meet the 300 MHz timing target.

- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_300m.sh`
- Geometry: TH16/MXU16/HBM4/DMA4/TMEM8; all-BRAM.
- Placement: `SSI_SpreadSLLs`; routing: `AlternateCLBRouting`; full SLR mode.
- Fresh source build, postfix `spread_v2`; no DCP retry and no RTL changes.
- Started: 2026-09-10 15:38:10 KST.
- Finished: 2026-09-10 23:29:49 KST; elapsed 7h51m39s; exit code 2.

## Hook verification

`slr_floorplan_report.tcl` now warns when a group has zero actual Laguna
TX/RX pairs. Direct FF pairing, group matching, and actual placed SLR ownership
remain mandatory. Eight Tcl fixtures passed, including fabric-register acceptance
and rejection of wrong-SLR placement.

Actual implementation `runme.log` confirms:

- Line 1345: post-init exact FF-pair validation passed.
- Line 1632: post-opt exact FF-pair validation passed.
- Line 2264: `mxu_output` zero-Laguna warning, continuing with fabric placement.
- Line 2265: post-place exact FF-pair validation passed.

## Routing failure

`runme.log:3173`: `Design is not legally routed. There are 921848 node overlaps.`
Line 3184 additionally reports partially-conflicted nets. Examples include the
core memory coalescer, TMEM request address, and HMSS `path_12` SLR transport.
These are examples, not an exhaustive attribution of congestion to one block.

The final router summary at lines 3019 onward reports:

| Metric | Value |
| --- | ---: |
| Unrouted nets | 0 |
| Partially routed nets | 0 |
| Node overlaps | 921,848 |
| Global vertical routing utilization | 29.5525% |
| Global horizontal routing utilization | 30.3202% |
| North maximum congestion, 64x64 area | 111.78% |
| South maximum congestion, 64x64 area | 114.848% |

Zero unrouted nets does not mean success: multiple signals still contend for
the same physical routing resources. Low whole-device utilization also does
not exclude local congestion. Reported north/south hot areas include
`INT_X64Y336 -> INT_X127Y399` and `INT_X64Y400 -> INT_X127Y463`.

## Frequency interpretation

The placed summary has WNS -7.993 ns, TNS -407884.656 ns, and 209389 setup-failing
endpoints. Routing logged intermediate WNS -12.238 ns at line 2967, but neither
is final legally routed timing. Do not convert those numbers into achieved
frequency or a proven Fmax.

The prior 100 MHz all-BRAM attempt produced a 100 MHz xclbin with final WNS
+0.003 ns. That remains the completed physical-build reference, not proof that
100 MHz is the maximum. This 300 MHz optimization attempt does not establish
an improved achievable clock. A subsequent, separately authorized fresh run at
an intermediate target would be needed to continue the search.

## Evidence

Build root:
`build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v2`

Output beneath that root:
`hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`

Implementation logs and reports beneath output:
`_x/link/vivado/vpl/prj/prj.runs/impl_1/`

- `runme.log`: actual hook execution and routing failure.
- `hw_bb_locked_timing_summary_placed.rpt`: placed timing only.
- `level0_wrapper_routed_error.dcp`: failure checkpoint, not reused or loaded.
- Runner state/log: `build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_300m_spread_v2/`.

Monitoring ended after detecting termination. No further build was launched.
