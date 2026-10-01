# Candidate FPGA utilization

Run from any working directory:

```bash
python /path/to/vortex_fpint/analysis_workspace/candidates_fpga_utils/main.py \
  --candidates C1,C2,C3,C4 --action total,breakdown
```

Both options also accept space-separated values. Omitting `--candidates`
selects all YAML entries; omitting `--action` selects both actions.
Use `--config`, `--alias-map`, `--output-dir`, and `--vivado` to override defaults.

## Candidate configuration

The driver reads `candidate_fpga_bins.yaml` beside the script. Values are aliases
from `ci/fpga_bin_alias_map.yaml` or FPGA build/bin directory paths. Direct relative
paths are resolved from the repository root, not the current working directory.
The alias resolver also respects `VORTEX_FPGA_BIN_ALIAS_MAP`.

```yaml
schema_version: 1
candidates:
  C1: tcu_th32_c1_rev2
  C2: build/hw/syn/xilinx/xrt/example_build
  C3: /opt/vortex_fpga_bins/example/bin
```

## Outputs

The default output directory is `results/` beside the script:

- `total.csv`: full FPGA use, including the shell; five resource rows per candidate.
- `breakdown.csv`: Vortex_axi use; five resource rows for each of SIMT,
  Cache/LMEM/TMEM, MXU, DMA, Misc, and Total Vortex_axi. TCU belongs to SIMT.
- `summary.md`: comparison tables, source reports, actual stages, and fallback details.

Both CSVs store `candidate,stage,resource,used,available,device_pct,source,fallback,status`.
Breakdown adds `category` after `stage`. All percentages are `used / full FPGA
capacity * 100`; partition percentages embedded in hierarchy reports are ignored.
For hierarchy reports without capacities, an explicitly identified U55C uses
LUT=1,303,680, FF=2,607,360, DSP=9,024, BRAM=2,016, URAM=960.
Other devices need a report with full-device capacities.

BRAM uses 36 Kb tiles: `RAMB36 + RAMB18 / 2`. Missing architecture categories are
zero. Unavailable results have empty counts and `status=unavailable`, not zero.
MXU includes the legacy GEMM unit, the current improve `u_VX_gemm_unit_v2`
(compute and accumulation), and the naive compute core plus its accumulation
unit (`u_acc_internal` or `u_VX_gemm_acc_lmem`). DMA includes TMEM engines,
scale/zero-point loaders, the improve DMA transport, and naive DMA executors,
output LMEM DMA, and the SLR DMA bridge. GEMM controllers remain in Misc.
An active GEMM node without a recognized MXU is rejected instead of silently
placing its compute resources in Misc. Patterns match the shared exporter in
`hw/syn/xilinx/xrt/export_util.tcl` and retain legacy report compatibility.
Only the requested action CSVs are written; a single-action rerun leaves the other
CSV untouched and the summary describes the current invocation.

## Report and checkpoint fallback

Total starts with `bin/impl_1_full_util_routed.rpt`; breakdown starts with
`bin/hier_utilization.rpt`. The driver searches only the selected build.

Total tries routed report copies, full placed reports, hw_bb_locked placed reports,
init reports, then the complete hierarchy report's top-level design counts.
Copies are searched under `bin/`, `_x/reports/link/imp/`, and
`_x/link/vivado/vpl/prj/prj.runs/impl_1/` in that order.
Breakdown first tries the implementation run's hierarchy report, then other
implementation utilization reports with usable hierarchy data.
Invalid or incomplete reports are rejected and listed in the summary.

The pre-opt hierarchy report is labeled `pre_opt` even when its header says
`Physopt postRoute`: that state can describe the preimplemented FPGA shell.
Init reports are labeled `linked`. A fallback retains its actual stage and path.
Hierarchical Total LUTs can differ from full-report CLB LUTs adjusted for LUT combining.

If no report is usable, Vivado exports a report from the latest saved implementation
checkpoint: postroute_physopt, routed, physopt, placed, opt. A saved failed-placement
checkpoint is also usable. Breakdown may additionally use the kernel synthesis DCP;
kernel-only checkpoints and reports cannot provide the full-FPGA total.
XPR is an alternative entrypoint into saved implementation/synthesis runs.
The driver never launches synthesis or implementation and requires no GUI.
It processes candidates sequentially, permits 30 minutes per extraction, and stores
generated reports, extraction Tcl, and logs under `results/reports/`.
When both reports are missing, it exports both from one checkpoint opening.

Exit codes: 0 for all requested results available (including fallback), 1 for any
unavailable result after processing the remaining candidates, 2 for invalid inputs.

## Tests

```bash
python -m unittest discover -s analysis_workspace/candidates_fpga_utils \
  -p test_candidates_fpga_utils.py -v
```

Tests include parity with the category patterns in `hw/syn/xilinx/xrt/export_util.tcl`
and therefore require `tclsh`. Report-only analysis requires Python and PyYAML;
Vivado is needed only when extracting missing reports.
