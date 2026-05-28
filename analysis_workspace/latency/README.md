# Latency Analysis Workspace

This directory contains FSDB and `simv.log` based latency-analysis helpers for
the fpint_naive repository. The main targets are:

- FPxINT naive GEMM, which uses the GEMM/MXU path.
- SGEMM TCU, which uses the tensor core path.

The main notebook is `cycle_analysis.ipynb`. The reusable implementation lives
in `cycle_util.py`.

## Reproducing Analysis

Use the `vortex` conda environment from the repository root:

```bash
conda activate vortex
python -m py_compile analysis_workspace/latency/cycle_util.py
```

Open `analysis_workspace/latency/cycle_analysis.ipynb` and run the fpint_naive
or TCU cells against traces under `build/logs`.

## Generated Tables

Long-form CSV files use `trace, section, metric, value, unit` style rows so new
metrics can be added without changing the schema. Compact CSV files pivot the
most useful metrics into one row per trace for quick comparison.

Important FPxINT outputs:

- `fpint_naive_phase_summary.csv`
- `fpint_naive_mpm_summary.csv`
- `fpint_naive_util_summary.csv`
- `fpint_naive_fire_interval_summary.csv`
- `fpint_naive_sync_wait_summary.csv`
- `fpint_naive_system_summary.csv`
- `fpint_naive_mxu_pipeline_summary.csv`
- Matching `*_compact.csv` files for the same metric groups.

Important TCU outputs:

- `tcu_nostall_tcu_summary.csv`
- `tcu_nostall_system_summary.csv`
- `tcu_nostall_tcu_breakdown_summary.csv`
- `tcu_nostall_trace_summary.csv`
- Matching compact CSV files for phase, MPM, utilization, fire interval, sync,
  and TCU metrics.

## Metric Groups

`phase`
: Runtime and kernel windows derived from FSDB core activity and `simv.log`
  symbols.

`mpm`
: RTL perf counters from GEMM/MXU and DMA blocks.

`fire_interval`
: Intervals between ready/valid fires for MXU, local DMA, and dcache DMA
  streams.

`system`
: HBM AXI, dcache interface, LMEM, and cache hit-rate metrics.

`mxu_pipeline`
: Internal FPxINT MXU valid/FIFO signals. `merger_in_valid` is the preferred
  event for estimating true MXU MAC count.

`tcu`
: TCU dispatch/commit latency, unit utilization, memory behavior, cache
  hit-rate, and kernel breakdown metrics.

## Interpretation Notes

FPxINT MPM `macs` is a writeback-proxy counter in the current RTL. It increments
on output LMEM fire, not on internal MXU result generation. For throughput
analysis, use:

```text
corrected_macs = merger_in_valid_events * MXU_ROW * MXU_COL
```

The current FPxINT bottleneck analysis is documented in
`result_interpretation/fpint_naive_gemm.md`. The TCU SGEMM analysis is
documented in `result_interpretation/tcu_gemm.md`.
