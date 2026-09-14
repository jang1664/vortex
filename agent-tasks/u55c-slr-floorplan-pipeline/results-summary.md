# SLR pipeline experiment results

Status: **100 MHz acceptance failed; routing and xclbin generation succeeded.**
Finalized: 2026-09-06 17:57 KST. The normal `slr_v7` build ended at 17:53
with exit code 0, after Vitis automatically reduced the kernel clock to
**78.4 MHz**. Build success is not 100 MHz timing closure.

The user requested that a failed `slr_v7` attempt end with a results
summary, without another RTL fix, synthesis, or implementation retry.

## Experiment

- Primary configuration: `improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`
  (TH16, MXU32, W4, eight response RAM slots).
- SLR0: eight HBM DMA channels, TMEM arrays/switches, TMEM DMA controller.
- SLR1: local DMAs, node/control, compute preparation and ACC.
- SLR2: complete MXU.
- Explicit registered inter-SLR transports; full-SLR hard pblocks; no narrow
  clock-region pblocks. Post-opt and post-place checks remain enabled.
- Vivado 2025.1, U55C, 100 MHz kernel target, Explore placement and
  AlternateCLBRouting. No OOC or checkpoint implementation retry.

## Completed checks

- Final RTL iteration 7: focused protocol and MXU32/MXU16 RAW/write-stall
  suites pass. Primary xrt-vcs-sim: all 12 runs pass numerical/protocol
  checks and each host-cycle sample is within 2% of the frozen baseline.
- Host-cycle medians (baseline -> current): smoke 5799 -> 5801;
  overlap 6474 -> 6549 (+1.158%); QROW 6176 -> 6175;
  odd tail 5873 -> 5872. This host metric does not hide the separately
  reported overlap compute-span increase: 566 -> 630 (+11.31%).
- Kernel synthesis: 447,646 LUT, 309,020 FF, 403.5 BRAM, 156 URAM,
  2,273 DSP. These totals match the preceding iteration-7 source runs;
  they are not a resource-delta claim against the original baseline.
- Actual post-init, post-opt, placement, and post-place checks pass.
  Hook failures were fixed, not bypassed: typed Vivado cell-object queries
  and homogeneous hierarchy ownership cover generated reset-helper shapes.
- Placed ownership matches the three intended SLRs. Boundary checks pass
  the existing per-group Laguna gate, but Input/Scale/Zero-point response
  data TX registers remain in SLICEs while RX registers are in Laguna.
  Do not interpret per-group PASS as complete both-Laguna bit coverage.

## Final physical results

| Check | Result |
|---|---|
| Requested / achieved kernel frequency | 100 / 78.4 MHz |
| Post-route physical-optimization setup | WNS -2.749 ns; TNS -23791.311 ns; 30,749 failing endpoints |
| Hold | WHS +0.006 ns; THS 0; zero failing endpoints |
| Routing | All 1,143,563 routable nets fully routed; zero routing errors, failed/unrouted/partially routed nets and final overlaps |
| DFX and bitstream precondition DRC | Zero errors |
| Routed bus-skew report | 195 reported paths, zero violations, worst slack +1.655 ns (HMSS; 2.222 ns requirement, 0.567 ns skew) |
| xclbin | Generated, 76,108,544 bytes; not tested on a board |

All 30,749 setup-failing endpoints belong to the 100 MHz kernel clock
group. Timing coverage reports zero unclocked register/latch pins and zero
unconstrained internal endpoints; seven input and three output ports lack
I/O delays and remain a coverage caveat. The bus-skew report is from the
routed reporting stage, before the final post-route physical optimization.
No extra final DCP audit was launched after the failed 100 MHz gate.

- Whole-design occupied CLBs: SLR0 95.26%, SLR1 75.96%, SLR2 42.38%.
  SLR0 exceeds the 80% review threshold despite LUT utilization of 61.93%.
  These totals include platform/HMSS and other non-GEMM logic.
- Routed boundary SLL usage: SLR0/1 50.70%, SLR1/2 32.54%; aggregate usage below
  the 65% review threshold does not exclude local congestion.
- Whole-design routed resources: 597,606 LUT, 510,579 registers, 602.5 BRAM,
  156 URAM and 2,277 DSP. These include platform/static resources and must
  not be directly compared with kernel-only synthesis totals above.
- During routing, high congestion made connectivity
  take precedence over timing. Estimated Global/Short congestion is level 6,
  and Timing congestion level 7. Routing eventually completed legally;
  this attempt did **not** fail because of unresolved routing collisions.
- Residual hotspot examples included Zero-point DMA slot-ownership metadata
  and CPU dispatch-buffer nets. These intermediate examples are not the
  final worst timing path or proof of one sole congestion source.

## Final bottleneck and top five setup paths

All five start at
`u_compute_core/g_slr_mxu_weight_rx.payload_q_reg[weight_sel]`, a Laguna
RX register in SLR2, and end in `u_mxu/u_weight_regs` within SLR2.
The selection signal chooses which of the two Weight storage regions to
read/shift and write. It drives **4,034 loads**. The worst path contains
only one LUT; **12.340 of 12.535 ns (98.44%) is routing delay**, including
12.013 ns on its first net. This is high-fanout distribution after the
crossing receiver, not a deep arithmetic chain or a data SLR crossing.
The report's `SLR Crossing[0->2]` label occurs on the clock leg.

Report: `hw_bb_locked_timing_summary_postroute_physopted.rpt`.
Destination prefix: `u_mxu/u_weight_regs/`.

| Report line | Destination suffix | Slack (ns) | Logic / route (ns) |
|---:|---|---:|---:|
| 2117 | `gen_row[15].gen_col[15].mem_reg[15][15][0][1]/D` | -2.749 | 0.195 / 12.340 |
| 2213 | `gen_row[5].gen_col[31].mem_reg[5][31][1][1]/D` | -2.748 | 0.184 / 12.247 |
| 2309 | `gen_row[25].gen_col[7].mem_reg[25][7][1][2]/D` | -2.745 | 0.134 / 12.218 |
| 2405 | `gen_row[0].gen_col[7].mem_reg[0][7][1][1]/D` | -2.743 | 0.145 / 12.399 |
| 2501 | `gen_row[8].gen_col[15].mem_reg[8][15][1][1]/D` | -2.734 | 0.194 / 12.324 |

Actual RTL anchors:

- `hw/rtl/core/gemm/VX_gemm_compute_core.sv:1582`: capture Weight metadata
  in the SLR2 RX FF; line 1588 unpacks the selection; line 1669 passes it
  to the MXU's `in_weight_sel_i`.
- `hw/rtl/core/gemm/VX_gemm_tree_v1.sv:107`: forward that selection to
  the Weight register array.
- `hw/rtl/core/gemm/VX_gemm_weight_regs_v1.sv:53` and line 59 select
  the source storage region for row/column shifts; lines 66 and 69 select
  the destination storage region.

The placed SLR1 dependency/child-queue chain is not the final worst path.
Clock uncertainty is 0.358 ns including 0.300 ns user margin. Removing that
margin alone would still leave about -2.449 ns slack; no margin or timing
exception was changed to claim success.

## Final verdict

The RTL/simulation and hook-debugging work is complete, and legal routing
has been demonstrated. **The 100 MHz physical target was not achieved.**
The generated xclbin advertises 78.4 MHz, not 100 MHz; no board performance
claim is made. As requested, stop here without further fixes or retries.
Changes remain uncommitted and no board was programmed.

Artifact directory:
`build/pnr/build_slr_hw/hw/syn/xilinx/xrt/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_slr_v7_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/`.
Frequency: `bin/vortex_afu.xclbin.info:54`.
Final timing and route/bus-skew reports: `_x/link/vivado/vpl/prj/prj.runs/impl_1/`.
The build's optional copies of `kernel_util_synthed.rpt` and
`kernel_util_routed.rpt` fail because those filenames are absent; make
explicitly ignores these report-copy errors. They are not the timing
failure or a failure to create the xclbin, and were not changed after
the user's stop instruction.

See [physical-results.md](physical-results.md) for the complete run history,
[simulation-results.md](simulation-results.md) for simulation evidence, and
[STATUS.yaml](STATUS.yaml) for the current execution/stop condition.
