# All-BRAM PnR result

Completed 2026-09-09 19:52:17 KST; final scheduled check at 20:06:44 KST.
The fresh source build returned 0 and generated a 77 MiB xclbin. Routing
completed without errors, but **100 MHz setup timing is still not met**.

## Comparison

Baseline: completed TMEM-only BRAM run in [previous results](../tmem-pnr/results.md).
Both runs use 100 MHz, full-SLR pipeline/floorplan, WLOAD=4,
SSI_SpreadSLLs placement and AlternateCLBRouting, with no DCP retry.

| Metric | TMEM-only BRAM | All-BRAM |
| --- | ---: | ---: |
| Achieved kernel-00 frequency | 95.4 MHz | 95.8 MHz |
| Final post-route-physopt WNS at 10 ns | -0.472 ns | -0.437 ns |
| TNS at 10 ns | -295.579 ns | -70.680 ns |
| Setup failing endpoints | 1,889 | 603 |
| WHS | +0.001 ns | +0.004 ns |
| Hold failing endpoints | 0 | 0 |
| Routing errors | 0 | 0 |
| CLB LUTs (placed) | 762,610 | 763,237 |
| CLB registers (placed) | 643,586 | 643,545 |
| BRAM tiles (placed) | 879.5 | 1,249.5 |
| URAM (placed) | 92 | 0 |
| DSP (placed) | 2,265 | 2,265 |

All-BRAM improved WNS by 0.035 ns and reduced the setup-violating endpoint count,
but did not remove the remaining bottleneck. The tradeoff is **370 extra BRAM
tiles** for removing 92 URAMs. LUT/FF deltas (+627/-41) are implementation-report
differences, not new RTL pipeline registers. This is one physical run per config,
not proof that the small WNS improvement will persist across placement variation
or future RTL changes. No further RTL change or retry was made.

## Memory mapping and SLR occupancy

Hierarchy evidence confirms:

- TMEM: 8 arrays x 16 RAMB36 = 128 RAMB36, unchanged from the TMEM-only BRAM run.
- ACC: 112 RAMB36 + 4 RAMB18 = 114 BRAM tiles, replacing 60 URAMs.
- Core local memory: 256 RAMB36, replacing 32 URAMs.
- Whole-design reported URAM usage: zero. Small LUTRAM/FF queues were not converted.

| SLR | Baseline BRAM tiles | All-BRAM tiles | All-BRAM utilization |
| --- | ---: | ---: | ---: |
| SLR0 | 497 | 497 | 73.96% |
| SLR1 | 200 | 570 | 84.82% |
| SLR2 | 182.5 | 182.5 | 27.16% |

The extra BRAM pressure is entirely in SLR1. The run remained routable, but this
substantially reduces its spare memory capacity. Fewer URAM constraints do not
mean uniformly less congestion. Routed SLL usage is 57.31% at SLR0/1 and 58.16%
at SLR1/2; those aggregate values do not measure local routing hot spots.

Resource comparisons use matching placed reports. Routed utilization also
confirms the same BRAM/URAM totals; no fresh post-physopt resource audit was run.

## Remaining worst path

The worst path is still in the core operand collector, not the ACC SRAM:

```text
opc_unit/pipe_reg2/.../pipe_reg[0][193]/C
  -> p_7_in (reported fanout 15,360; SLR1 -> SLR2 crossing)
  -> LUT6
  -> opc_unit/out_buf/.../data_out_r_reg[1334]/D
```

RTL instances: [VX_opc_unit.sv:208](../../../hw/rtl/core/VX_opc_unit.sv:208)
(`pipe_reg2`) and [VX_opc_unit.sv:306](../../../hw/rtl/core/VX_opc_unit.sv:306)
(`out_buf`). The optimized bit 193's precise field meaning was not decoded here.

Data-path delay is 9.901 ns: 0.229 ns logic and 9.672 ns routing (97.687%),
with only one logic level. The dominant source net alone accounts for 9.621 ns
and crosses SLR1 to SLR2. This supports investigating high-fanout distribution
and physical placement of this core path; changing additional memory primitives
did not eliminate it. WNS also includes clock skew/uncertainty and inter-SLR
compensation, so it is not simply 10 ns minus data-path delay.

## Verification and flow

- Seven focused VCS checks passed via `tools/verify_rtl.py`: TMEM, active GEMM
  backpressure, and legacy GEMM with both ACC choices, plus omitted-TMEM default0.
- Four fpint GEMM xrt-vcs-sim cases passed: smoke, overlap, QROW, odd-tail.
  No trace failures; response-slot accounting balanced. This was functionality
  verification, not a matched performance A/B.
- Fourteen config/ini integration tests passed. Post-init, post-opt and
  post-place SLR marked-group/FF-pair validation passed in the actual build.
- All 1,382,048 routable nets are fully routed, routing errors zero.
- An optional `impl_1_kernel_util_routed.rpt` copy warning was ignored by the
  existing Makefile; it did not prevent binary generation or change exit status.
- Runtime: 8h 45m 33s including configure. Monitoring has ended.

## Evidence paths

All paths below are relative to the repository root unless otherwise noted.

Build output prefix:

```text
build_timing_cuts_pnr_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram_spread_v1/hw/syn/xilinx/xrt/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/
```

Within that output directory:

- `bin/vortex_afu.xclbin`: generated binary.
- `bin/vortex_afu.xclbin.info:54`: requested and achieved kernel-00 clocks.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:166`: final timing summary; worst path starts at line1997.
- Same implementation directory, `hw_bb_locked_route_status.rpt`: final routing status.
- `hw_bb_locked_utilization_placed.rpt:114`: memory totals; per-SLR table at line473.
- `hier_utilization.rpt:3955`: ACC; line5253 onward: TMEM; line5834: local memory.
- `slr_util_routed.rpt`: routed SLR resource/connectivity report.
- `runme.log`: actual directives and SLR-hook results.

Runner state and source manifest:
`build_timing_cuts_pnr_artifacts/th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram_spread_v1/`.
Monitor history: `build_timing_cuts_pnr_artifacts/all_bram_spread_v1_monitor/history.jsonl`.
Simulation evidence: `build_all_bram_verify_v1/evidence/summary.json`.
