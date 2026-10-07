# Rev5 figure rebuild

Tag: `th16_20261007_rev5_pipeline`. Requested on 2026-10-07.

Status: complete. All 11 render jobs produced PNG/PDF/SVG (33 images).
Both models contain 247,170 composed rows, with no missing latency/power or
duplicate cases. Every composed source-image hash matches its application's
captured selection. All six raw database hashes are unchanged. The E2E PNG was
also opened for visual inspection. See `completion.json` for verification.

This is an offline figure rebuild from the current rev5 raw databases. It does
not run hardware, power acquisition, or new refinement probes. The stopped
`rev5_pv_slow_repeat` experiment is not used. Composition recomputes interpolation
from the preserved measured points using the existing composer.

## Mixed-image provenance

Rev5 intentionally combines newly measured C4 `fpint_gemm_ffn_hw` with preserved
rev4 measurements for all other applications. A single current-C4 snapshot would
exclude the retained vector data. The existing rev5 generated suites were also
restricted to the C4 remeasurement; a full pipeline generation attempt rejected
the different captured selection. No selection guard was changed.

`build_plot_inputs.py` therefore creates a separate offline suite view under
`suites/`. It uses the complete rev4 model workloads, retaining all shapes and
measurement/reuse/interpolation rules. Only the C4 GEMM application's captured
image selection is updated to the rev5 snapshot. Every other application retains
its original snapshot. These are plot inputs, not suites intended for new hardware
execution. The regular rev4/rev5 generated suite directories are not replaced.

Before composition, all six rev5 raw databases are checked row by row for their
candidate label, alias, and image SHA against that per-application policy.
`input_inventory.json` records their content hashes and each derived suite's
source and output hashes. No raw row is relabeled to another image.

The kernel-power renderer accepts a single image per candidate, so its explicit
six raw inputs use the same separately validated mixed-image policy. Its
`power_selection.json` records both snapshots and the inventory. The empty
single-image filter in that file means to retain the validated explicit inputs;
it does not claim that all C4 measurements used the new image. Other raw database
directories and the stopped repeated-measurement results are not read.

## Execution

Run from the repository root:

```bash
bash analysis_workspace/latency_on_hw/docs/rev5_plot_refresh/run.sh
/home/jaeyongjang/.conda/envs/vortex/bin/python \
  analysis_workspace/latency_on_hw/docs/rev5_plot_refresh/verify.py
```

The launcher uses the existing `run_compose.py`, `prepare.py`, and `plot.py`
implementations. Composition retains `--missing error` and full latency/power
completeness checks. Plot selection is `all`, with output tokens 128 and formats
PNG/PDF/SVG. It creates 11 render jobs: E2E latency with/without area normalization
and Hadamard, GEMM breakdown with/without area normalization, four energy views,
and kernel dynamic power.

Outputs under `analysis_workspace/latency_on_hw/`:

- `composed_results.th16_20261007_rev5_pipeline/`
- `figure_prepare.th16_20261007_rev5_pipeline/`
- `figure_output.th16_20261007_rev5_pipeline/`

Logs: `compose.log`, `prepare_llama2_7b.log`, `prepare_llama3_8b.log`, `plot.log`,
and `session.log`. Final verification is recorded in `completion.json`, including
unchanged raw hashes, per-model completeness, source-image matching, and the full
expected plot artifact inventory. No new run/refine pipeline receipts are claimed.
