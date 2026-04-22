# Implementation Verification Checklist — Route Congestion Fix

Verification steps for re-running the `core1_fpint_improve_v3` build after
the DMA engine BRAM refactor + `gen_acc_mem` URAM opt-in + SLR floorplan
pblocks landed. Tracks which metrics must pass at each flow stage, where
to find them, and what to do when they don't.

Companion to `agent-tasks/dma-engine-route-fix/fix-plan.md`.

---

## Baseline (v3)

The original failing build produced these reference numbers — use them as
the comparison baseline:

| Metric                     | v3 value                         |
|----------------------------|-----------------------------------|
| `u_dma_engine` LUT         | 110 113                           |
| `u_dma_engine` FF          | 197 294                           |
| `u_dma_engine` RAMB36      | 0                                 |
| `u_dma_engine` URAM        | 0                                 |
| `u_VX_gemm_unit` URAM      | 60                                |
| Device URAM total          | 188 (60 + 64 + 64)                |
| SLR0 CLB                   | 85.67 %                           |
| SLR1 CLB                   | 91.19 %                           |
| SLR2 CLB                   | 55.98 %                           |
| SLR[0-1] SLL worst col     | 179 / 128 / 118 / 128 %           |
| Global congestion hotspot  | 64×64 North @ ~100 %              |
| Post-route node overlaps   | 311 (ERROR [Route 35-2])          |

---

## Stage 1 — Post-synth / init_design

Report file path:
```
build/hw/syn/xilinx/xrt/<build>/_x/link/vivado/vpl/prj/prj.runs/impl_1/init_report_utilization_0.rpt
```

| # | Check                                  | Expected                         | If fail                                    |
|---|----------------------------------------|-----------------------------------|--------------------------------------------|
| 1 | `u_dma_engine` RAMB36                  | > 0 (~60–128)                     | Stage 2: `VX_dp_ram` wrap (fix-plan §4.1)  |
| 2 | `u_dma_engine` URAM                    | 0                                 | Check `VX_sp_ram` USE_URAM branch leak      |
| 3 | `u_VX_gemm_unit` URAM                  | 60                                | Re-confirm `USE_URAM(1)` in `VX_gemm_unit.sv:1170` |
| 4 | Device URAM total                      | ~188 (60 acc + 64 tmem + 64 lmem) | If only ~60 → tmem/lmem `USE_URAM(1)` not applied |
| 5 | `u_dma_engine` FF                      | ~135 K (from 197 K)               | Paired with #1: BRAM infer failed          |
| 6 | `u_dma_engine` LUT                     | ~90 K (from 110 K)                | Paired with #1                             |

**Gate**: if #1 is 0, stop before place_design and refactor to Stage 2.
No point spending placement time on a design that still has the FF
windows.

---

## Stage 2 — post_init hook firing

Grep the impl_1 runme.log:

```
build/hw/syn/xilinx/xrt/<build>/_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log
```

| # | Check                                 | Expected log line                                             | If fail                                  |
|---|---------------------------------------|----------------------------------------------------------------|-------------------------------------------|
| 7 | No `INFO: pblock pblock_*` log          | absent (no active pblocks in current iteration) | If present, `floorplan.tcl` regression — someone re-enabled a pblock. |
| 9.1 | No `[Place 30-887]` RP clock-column violation | grep returns nothing                              | Pblock spans multiple SLRs in an XRT RP. Shrink to one SLR. |

---

## Stage 3 — Post-place

Same `runme.log`. Look for the post-place summary sections. Also check
`slr_util_placed.rpt` in the same directory.

| #  | Check                              | Expected                                      | If fail                                   |
|----|------------------------------------|------------------------------------------------|-------------------------------------------|
| 10 | SLL demand SLR[0-1] per column     | All columns < 100 %                            | Fallback: shrink `pblock_gemm_unit` to SLR2 only, or widen `pblock_tmem_subsystem` to SLR0 + SLR1 low CRs |
| 11 | SLL demand SLR[1-2] per column     | All columns < 100 %                            | Fallback: move some GEMM logic back toward SLR1 |
| 12 | Global congestion hotspot region   | ≤ 32×32 (baseline was 64×64)                   | `place_design -directive Explore`; revisit pblocks |
| 13 | SLR0 CLB utilisation               | < 95 %                                         | TMEM is over-packed; split TMEM banks across SLR0 + bottom of SLR1 |
| 14 | SLR1 CLB utilisation               | < 85 % (baseline 91 %)                         | Push more GEMM logic to SLR2 via pblock trim |
| 15 | `gen_acc_mem` URAM SLR_INDEX       | ∈ {1, 2}                                       | pblock may be ignored — re-check `contain_routing` state |
| 16 | TMEM bank BRAM/URAM SLR_INDEX      | 0                                              | Same as #15                                |

**Gate**: if any of #10–#12 still shows overflow, stop and revise the
floorplan before spending ~5 h on route.

Grep recipes:

```bash
LOG=build/.../impl_1/runme.log

grep -E "Estimated SLL Demand Per Column" -A 3 $LOG
grep -E "Post-Placement Estimated Congestion" -A 15 $LOG
```

---

## Stage 4 — Post-route

| #  | Check                          | Expected                                     | If fail                                 |
|----|--------------------------------|-----------------------------------------------|------------------------------------------|
| 17 | Node overlaps                  | `Number of Node Overlaps = 0`                 | Inspect remaining overlap nets; if write-window nets reappear, queue write-window BRAM follow-up |
| 18 | `[Route 35-2]` absent          | grep returns nothing                          | Same as #17                              |
| 19 | `[Route 35-162]` absent        | No "signals failed to route"                  | Congestion analysis with `report_design_analysis -congestion` |
| 20 | Routed DCP filename            | `level0_wrapper_routed.dcp` (no `_error`)     | —                                        |
| 21 | Timing WNS                     | ≥ v3 baseline (i.e. not worse)                | If negative: BRAM clock-to-out is likely culprit — add a pipeline stage before AXI W (deferred anyway for write windows); or retime `burst_rsp_data_r` path |

---

## Grep Command Cheat Sheet

```bash
# Set once
BUILD=build/hw/syn/xilinx/xrt/<run_dir>
LOG=$BUILD/_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log
UTIL=$BUILD/_x/link/vivado/vpl/prj/prj.runs/impl_1/init_report_utilization_0.rpt
SLR=$BUILD/_x/link/vivado/vpl/prj/prj.runs/impl_1/slr_util_placed.rpt

# Stage 1 — resource
awk -F'|' '/u_dma_engine|u_VX_gemm_unit/ {print $2, "| RAMB36=", $11, "URAM=", $13, "LUT=", $6, "FF=", $10}' $UTIL

# Stage 2 — hook firing
grep -E "pblock pblock_(gemm_unit|tmem_subsystem)" $LOG
grep -E "WARNING: (u_VX_gemm_unit|u_tmem_subsystem) not found" $LOG

# Stage 3 — post-place congestion
grep -E "Estimated SLL Demand Per Column" -A 3 $LOG
grep -E "Post-Placement Estimated Congestion" -A 15 $LOG
grep -E "CLB +\|" $SLR | head

# Stage 4 — route result
grep -E "Number of Node Overlaps|\[Route 35-(2|162|3311)\]" $LOG
ls -la $BUILD/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed*.dcp
```

---

## Priority Map

| Priority | Check IDs        | When to act                                 |
|----------|------------------|----------------------------------------------|
| **P0**   | 1, 3, 7, 9, 9.1  | Any fail → stop the run, fix before place    |
| **P1**   | 10, 11, 12       | Any fail → stop before route, revise floorplan |
| **P2**   | 13, 14, 15, 16   | Fail is informative, not necessarily blocking |
| **P3**   | 17 – 21          | Definitive success criteria                  |

---

## Expected Outcome Summary

After v3_run2 completes cleanly, expect:

- `u_dma_engine`: ~64 RAMB36, 0 URAM, ~135 K FF, ~90 K LUT.
- `u_VX_gemm_unit`: 60 URAM in SLR1 / SLR2.
- `u_tmem_subsystem`: ~512 RAMB36 in SLR0.
- Device URAM total: ~60 (down from 188).
- Device RAMB36 total: ~912 + whatever `local_mem` / `l2cache` spill
  (monitor; may add another 64–128 RAMB36 per module).
- SLL demand: no column over 100 % on either SLR boundary.
- Route: 0 node overlaps; `level0_wrapper_routed.dcp` generated.

Report discrepancies against this summary back to the fix-plan
`§9 Checklist` so the remaining follow-ups (write-window refactor,
`local_mem` / `l2cache` URAM opt-in, timing tuning) can be triaged.
