# Source join FF and geometry width reduction

Implementation, directed verification, blackbox replays and 100 MHz PnR are complete. Bitstream and xclbin packaging passed, with DATA_CLK selected at 100 MHz. The requested compute/stall metric remains unavailable because its counters are unimplemented.

## RTL

- Register all producer closure and four engine read-completion events together. Preserve owner feedback and 32-bit count validation. Pending valid events prevent quiescence; reset clears them and invocation start requires a drained stage.
- Derive microtile count/index widths from geometry. MXU16 count/count/product/index/index widths: 4/4/7/3/3. MXU32: 3/3/5/2/2. Preserve 32-bit clamp/ceil arithmetic and zero-extend the product to the existing output.
- Only `VX_naive_source_join.sv` and `VX_gemm_fsm_naive_meta.sv` change. Both are excluded from improve compilation. The pre-edit manifest covers 344 RTL files; every other file is identical. Four improve preprocessing comparisons (two modules, PERF off/on) pass. No improve synthesis is performed.

## Functional verification

58 VCS cases pass, including 24 deliberately malformed inputs which trigger the required DUT assertion. The 16 FSM command streams pass the frozen independent oracle; 16 integrated control CMD/CLOSE streams match those references exactly. See `verification/tests-report.md` and `verification/unittests/results.json`.

## Performance measurement caveat

The actual shared `VX_gemm_compute_core` starts its PERF output at zero and never assigns `compute_cycles` or `stall_cycles`. Both naive and improve therefore print zero for these fields before this change. They cannot demonstrate latency equality and a percentage change from this baseline is undefined. No total/core counter is substituted for the requested primary metric. The user declined additional PERF instrumentation; no counters were added. The requested follow-up comparison uses the existing GEMM total_cycles values below.

All runs use M=1/4/256, K=N=256, QBLK=32, QDIR=WTRANS=0, REPS=1 and `--perf 3` through `ci/run_black.sh xrt-vcs-sim` in the configured XLEN64 build. `run-perf.sh` retains raw logs, actual simulator config, source/config/compiler environment and binary hashes. The simv configuration stamp is explicitly invalidated before each series because its make rule does not track library RTL files.

## PnR comparison baseline

Prior naive+TCU base: 100 MHz requested, WNS -0.411 ns, TNS -227.754 ns, 985 setup failing endpoints, hold WHS/THS 0/0 and no hold failing endpoints. Bitstream and xclbin completed, but selected DATA_CLK was 96 MHz. Final checkpoint utilization: 526722 LUTs, 573398 registers, 1182 DSPs and 975.5 BRAM tiles. These counts were extracted read-only from the archived postroute-physopt DCP; no baseline synthesis was rerun.

The old worst path was K -> closure count -> source_join owner enable. Archived reports are under `baseline/pnr/`. New `run-pnr.sh` uses the identical config, default place/route directives, local execution, 100 MHz, SLR floorplan, FAST_MODE=0 and PERF/DEBUG disabled, with a unique timestamp postfix.

## Measured results

Primary metric (raw `--perf 3` output):

| M | Before compute_cycles | After compute_cycles | Delta | Change | Numerical result |
|---|---:|---:|---:|---:|---|
| 1 | 0 | 0 | 0 | undefined (zero baseline) | PASS |
| 4 | 0 | 0 | 0 | undefined (zero baseline) | PASS |
| 256 | 0 | 0 | 0 | undefined (zero baseline) | PASS |

The zero compute/stall values are unimplemented counters, not a latency measurement. No performance conclusion is drawn from them.

Supplementary live counters (not substitutes for compute_cycles):

| Backend | M | GEMM total before | GEMM total after | Core before | Core after |
|---|---:|---:|---:|---:|---:|
| naive | 1 | 3244 | 3244 | 9804 | 9804 |
| naive | 4 | 3639 | 3639 | 10179 | 10179 |
| naive | 256 | 81688 | 81706 | 88254 | 88254 |
| improve | 1 | 2378 | 2378 | 8148 | 8148 |
| improve | 4 | 2453 | 2453 | 8224 | 8224 |
| improve | 256 | 80570 | 80570 | 86376 | 86376 |

Naive M256 GEMM total rises 18 cycles (0.0220%); its core cycle count stays unchanged. The added input register delays source-free publication by one cycle, which can delay subsequent buffer reuse through SRC_FREE synchronization. This explains a possible latency mechanism, but the exact 18-cycle decomposition is not established by these logs. The kernel polls MMIO completion, so core cycles need not change with each GEMM-cycle change. Stall counters cannot diagnose the difference because they are also unimplemented.

Improve selected RTL is identical and GEMM/core deltas are zero for all shapes. All 12 before/after blackbox numerical checks pass.

## Final physical implementation

The local run started at 2026-09-17 01:26:22 KST with postfix
`source_join_ff_bw_20260917_012622`. The generated kernel clock constraint is
10.0 ns. Marked-group and exact FF-pair SLR validation passed after init,
optimization and placement. See `pnr/final-floorplan-and-clock.log`.

The postroute-physopt report gives the following signoff timing. Global values
include the platform; kernel values refer to `clk_kernel_00_unbuffered_net`.

| Metric | Previous base | New run |
|---|---:|---:|
| Global setup WNS (ns) | -0.411 | +0.003 |
| Kernel setup WNS (ns) | -0.411 | +0.064 |
| Setup TNS (ns) | -227.754 | 0 |
| Setup failing endpoints | 985 | 0 |
| Global/kernel hold WHS (ns) | 0 | +0.004 |
| Hold THS (ns) | 0 | 0 |
| Hold failing endpoints | 0 | 0 |
| Pulse-width failing endpoints | 0 | 0 |

Comparable utilization extracted read-only from both final postroute-physopt
checkpoints (whole design, including platform):

| Resource | Previous base | New run | Delta |
|---|---:|---:|---:|
| LUT | 526722 | 526672 | -50 |
| FF | 573398 | 573651 | +253 |
| DSP | 1182 | 1178 | -4 |
| BRAM tiles | 975.5 | 975.5 | 0 |
| URAM | 0 | 0 | 0 |

These are final implementation differences, including physical optimization;
the FF delta is not the RTL declaration count. The input stage declares 198
bits; the final checkpoint contains 174 cells matching the input-event
register names after synthesis and physical optimization.

### Critical paths

The old worst kernel path was K geometry/count to source_join owner enable:
slack -0.411 ns, data delay 9.854 ns, logic/route 4.265/5.589 ns, 27 levels.
The new register boundary separates this cone:

| New path | Slack (ns) | Data delay (ns) | Logic/route (ns) | Levels |
|---|---:|---:|---:|---:|
| Job K to closure-count input FF | +4.989 | 4.560 | 1.171 / 3.389 | 9 |
| Input event FF to owner | +1.710 | 7.876 | 1.395 / 6.481 | 11 |
| Worst kernel: AXI request crossbar to HBM mux spill register | +0.064 | 9.637 | 0.204 / 9.433 | 1 |

The new worst path starts at request-crossbar output-buffer valid and ends at
HBM mux 6 spill-register data bit 289. Routing accounts for 97.883% of its
data delay. There are no remaining negative-slack kernel endpoints; the
remaining narrow margin is in AXI/HBM routing, not the former source_join
count cone. This single successful run establishes closure for this artifact,
not additional margin across changed placement seeds or constraints.

Full path reports, final resources and the empty failing-path table are under
`pnr/analysis/`; extraction completed with exit code 0. `analyze-pnr.tcl` opens
the existing checkpoint and only runs reports.

### Deliverables and clock decision

- Bitstream generation: PASS.
- Xclbin packaging: PASS; local wrapper exit code 0, completed at 07:07:57 KST
  (about 5 h 41 min after launch).
- 100 MHz timing closure: PASS. The final clock period is 10 ns, no
  setup/hold/pulse-width endpoint fails, and both xclbin DATA_CLK and system
  achieved frequency are 100 MHz. The previous xclbin selected 96 MHz.
- Auto-frequency scaling estimated 100.6 MHz and capped the selection at the
  requested 100 MHz. There was no downward frequency fallback.

Final [xclbin](/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_source_join_ff_bw_20260917_012622_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin); [clock metadata](pnr/vortex_afu.xclbin.info).
Artifact sizes and SHA-256 hashes are in `pnr/artifacts.json`; structured
before/after results are in `pnr/results.json`.

The report-copy target emitted two ignored missing-file errors for legacy
`impl_1_kernel_util_synthed.rpt` / `impl_1_kernel_util_routed.rpt` names after
successful linking. They did not affect bitstream, packaging or timing.
Final resource reports were independently extracted from the final DCP under
`pnr/analysis/`; the requested comparisons are complete.

The compute_cycles/stall_cycles limitation remains: raw outputs are preserved,
but they cannot measure compute latency. The user declined counter changes
and requested the existing total_cycles comparison instead; those measured
values are reported above.

Raw logs, reports, environment snapshots and binaries referenced here are local
execution evidence excluded from Git. This commit retains the interpreted
results, test helpers and reproduction scripts. `check-improve.py` records
the original pre-commit check against HEAD and expects that original worktree
state; its retained receipt describes the completed comparison.
