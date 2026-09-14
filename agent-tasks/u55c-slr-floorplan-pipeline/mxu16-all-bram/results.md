# MXU16 all-BRAM physical result

The fresh source PnR completed successfully on 2026-09-10 at 01:40:36 KST,
exit0, generating a 64MiB xclbin. Elapsed time including configure: 3h42m11s.
Final reports were checked at 01:54 KST; monitoring is complete.

## Timing and routing

| Metric | Result |
| --- | ---: |
| Requested / achieved kernel-00 frequency | 100 / 100 MHz |
| Final post-route-physopt setup WNS | +0.003 ns |
| TNS / failing setup endpoints | 0 ns / 0 |
| WHS / failing hold endpoints | +0.004 ns / 0 |
| Pulse-width violations | 0 |
| Routable / fully routed nets | 843,550 / 843,550 |
| Routing errors | 0 |

The final report states all user-specified timing constraints are met. Setup
margin is only **3ps**: this is a successful run, not a robustness guarantee
across future RTL or placement changes.

## Resources

Whole-design placed report (not a new post-physopt resource audit):

| Resource | Used |
| --- | ---: |
| CLB LUTs | 443,158 |
| CLB registers | 429,534 |
| BRAM tiles | 991.5 |
| URAM | 0 |
| DSP | 818 |

| SLR | BRAM tiles | Utilization |
| --- | ---: | ---: |
| SLR0 | 596 | 88.69% |
| SLR1 | 345.5 | 51.41% |
| SLR2 | 50 | 7.44% |

The all-BRAM objective is realized: reported URAM count is zero. SLR0 BRAM
occupancy is high even though the complete device uses 49.18% of BRAM tiles.

## Flow and verification scope

- Exact config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh`.
- TH16 / MXU16x16 / WLOAD4 / HBM4 / DMA4 / eight 32B TMEM arrays.
- Full-SLR pipeline/floorplan, SSI_SpreadSLLs placement, AlternateCLBRouting;
  no ultrathreads, no congestion early-fail gate, no DCP retry or RTL edits.
- Post-init, post-opt and post-place SLR marked-group and exact FF-pair
  validation passed in the actual implementation run.
- Config sourcing, shell syntax and generated-INI settings were checked.
  Historical MXU16 tests and memory-selection tests are documented in README;
  no fresh exact-profile xrt-vcs-sim or FPGA hardware execution was performed.
- An ignored optional report-copy warning for missing
  `impl_1_kernel_util_routed.rpt` did not affect binary generation or exit status.

## Artifacts

Output directory, relative to repository root:

```text
build/pnr/build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_spread_v1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/
```

Within that directory:

- `bin/vortex_afu.xclbin`: generated binary.
- `bin/vortex_afu.xclbin.info:54`: requested/achieved clocks.
- `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt:166`: final timing.
- Same implementation directory: `hw_bb_locked_route_status.rpt` (routing),
  `hw_bb_locked_utilization_placed.rpt:114` (memory totals; SLR table line495),
  `runme.log` (directives and hook checks).

Runner identity and source hashes:
`build/pnr/build_timing_cuts_pnr_artifacts/th16_tcol16_m16_t8_bigmem_all_bram_spread_v1/`.
Actual monitor timestamps:
`build/pnr/build_timing_cuts_pnr_artifacts/mxu16_all_bram_spread_v1_monitor/history.jsonl`.
