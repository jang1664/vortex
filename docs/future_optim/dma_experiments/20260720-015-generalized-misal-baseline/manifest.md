# Generalized Misaligned DMA Pre-change Baseline

## Experiment identity

| Field | Value |
| --- | --- |
| Experiment ID | `20260720-015-generalized-misal-baseline` |
| Purpose | Lock matched node-backend OOC inputs before replacing the misaligned DMA payload datapath |
| Parent design | `20260718-013-misaligned-response-wrbuf1` |
| Fixed baseline | This experiment |
| Production RTL changes | None |
| Measurement harness changes | `ci/run_dma_ooc.sh`, `hw/syn/xilinx/dut/VX_dma_unit_ooc.sv`, `hw/syn/xilinx/dut/ooc_synth.tcl` |
| Git commit | `b07d1c24620ee5393e6d12bc1b2f9467a268461e` |
| Git branch | `fpint` |
| Pre-change RTL SHA-256 | `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f` |
| Backup | `hw/rtl/core/VX_dma_unit_misal.sv.pre_generalize_20260720.bak`, byte-identical |
| Vivado | 2025.1, `xcu55c-fsvh2892-2L-e` |
| OOC top | `VX_dma_unit_ooc` |
| Constraint | `hw/syn/xilinx/dut/project.xdc`, 100 MHz |
| Comparison rule | Old and new rows must match every recorded manifest field and source/input hash |

The working tree already contained user changes in `configs/tcu_th16_c1.sh`,
`configs/tcu_th16_c2.sh`, `configs/tcu_th16_c4.sh`,
`configs/tcu_th32_c1.sh`, and `hw/rtl/core/VX_dma_unit_align.sv`. They are
preserved. Every OOC row records the complete dirty state plus hashes of all
explicit sources so the same source closure can be reproduced.

## Required OOC rows

| Row | Config | Dcache | LMEM | Direction | Artifact |
| --- | --- | ---: | ---: | ---: | --- |
| Primary old RTL | `configs/improve_th32_tcol32_hwexp_dcache.sh` | 64 B | 256 B | `-1` runtime | `ooc/64x256-runtime-constrained-v2/` |
| HBW old RTL | `configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh` | 512 B | 512 B | `-1` runtime | `ooc/512x512-runtime-constrained/` |

Each row is created by `ci/run_dma_ooc.sh` and contains `command.txt`,
`manifest.txt`, `configs.txt`, `sources.txt`, `source_sha256.txt`,
`input_sha256.txt`, `git_status.txt`, `run_status.txt`, and either the completed
raw Vivado reports or the preserved console/journal/failure state.

The primary row required two constraint-harness corrections before the locked
PASS artifact. `ooc/64x256-runtime/` preserves the initial report with board
I/O unconstrained, and `ooc/64x256-runtime-constrained/` preserves the failed
attempt that used the unsupported Synopsys `remove_from_collection` command.
Neither is an adoption baseline. The `-constrained-v2` row uses Vivado-native
port filtering and is the only primary comparison baseline.

## Fixed HBW fallback LUT budget

`HBW_DMA_LUT_BUDGET=40000`

The failed full-design PACK16 run is preserved at:

- Build: `build/hw/syn/xilinx/xrt/improve_th32_tcol32_hwexp_dcache_pack16_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`
- DMA allocation report: `_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt`
- Placed utilization report: `_x/link/vivado/vpl/prj/prj.runs/impl_1/full_util_placed.rpt`
- Per-SLR report: `_x/link/vivado/vpl/prj/prj.runs/impl_1/slr_util_placed.rpt`
- Route failure report: `pnr_route_status.rpt`

The placed `u_VX_dma_node/u_dma_unit` consumes 52,333 LUTs. The design uses
93.90% of CLBs overall, with SLR0 and SLR1 at 98.01% and 97.75% CLB occupancy,
and routing ended with 225,279 nets in resource conflict. The 20% primary
reduction threshold would permit 41,866 LUTs. The fixed 40,000-LUT fallback
budget is deliberately tighter: it requires a 12,333-LUT (23.56%) reduction
from the failed-build DMA allocation and retains 1,866 LUTs of margin below the
minimum 20% threshold. This is an OOC candidate gate, not a claim that the
full-design placement and routing failure is solved.

The hierarchy value was extracted with:

```text
/home/jaeyongjang/.conda/envs/vortex/bin/python tools/vivado_util.py \
  <hier_utilization.rpt> show utilization_by_hierarchy \
  --filter 'u_VX_dma_node/u_dma_unit$' --format csv
```

## Locked integration workloads

The plan's integration metric is the aggregate `PERF: ... cycles=` value from
the `xrt-vcs-sim` application log. A candidate above 101% of its matched fresh
old-RTL value is rejected.

| Workload | Config | Application and arguments | Fresh old-RTL observation | 101% ceiling | Artifact |
| --- | --- | --- | ---: | ---: | --- |
| C4 | `configs/improve_th16_tcol32_hwexp_dcache.sh` | `fpint_gemm_ffn_hw -m 128 -k 128 -n 128` | 11,743 cycles, PASS | 11,860 cycles | `blackbox/c4-old-v2/` |
| HBW | `configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh` | `fpint_gemm_ffn_hw_naive -m 128 -k 128 -n 128` | 17,641 cycles, PASS | 17,817 cycles | `blackbox/hbw-old/` |

These are the final R13 denominators and were force-rebuilt from the backed-up
old RTL. The C4 workload uses the current C4 application ABI. The attempted
historical `_naive` C4 application is incompatible with the current C4
channel-slot assertion; its expected failure is retained at `blackbox/c4-old/`
instead of being silently substituted. Historical 12,137-cycle C4 and
18,055-cycle HBW observations remain characterization references only.

## Status

- OOC 64 B / 256 B runtime: PASS; 53,049 LUTs, 7,961 FFs, 33 RAMB36,
  2 RAMB18, 16 DSPs, and +0.725 ns WNS at 100 MHz. `check_timing` reports zero
  unconstrained internal endpoints, zero undelayed data inputs, and zero
  undelayed outputs; reset is explicitly false-pathed.
- OOC 512 B / 512 B runtime: TIMEOUT at the fixed 1,800-second limit while
  Vivado was in timing optimization. Peak memory before that phase was
  4,977.738 MB. No complete utilization or timing report exists, so candidate
  HBW evaluation uses the fixed 40,000-LUT fallback budget. See
  `ooc/512x512-runtime-constrained/run_status.txt` and `timeout.md`.
- Fresh matched integration cycles: PASS and retained with raw logs.
- Conclusion: U1 baseline capture is complete. Compare 64 B / 256 B candidates
  against the constrained PASS row, HBW candidates against the fixed fallback
  budget, and performance against the fresh cycle denominators above.
