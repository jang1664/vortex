# Llama hardware latency and power measurements

`candidate_fpga_bins.yaml` selects the C1–C4 aliases from
`ci/fpga_bin_alias_map.yaml`. The workflow does not change the global C1–C4
aliases. TCU GEMM comes from C1, naive GEMM from C3, and improved GEMM from C4.
All vector, layout, and quantization kernels (including fused variants) execute
on C1. Logical C2 combines C1 TCU/vector results with C3 naive GEMM results.
Registering a C2 image never creates a C2
measurement or refinement task. C4_fused remains included and C4_alone remains
excluded.

The local `candidate_fpga_bins.yaml` is the source of truth for image aliases.
Execution sources are C1, C3, and C4; logical C2 has no independent raw database.

The default experiment tag is `C3_C4_v3_pipeline`. Results use logical execution
labels (`C1`, `C3`, `C4`), so C4 measurements are saved under `C4/` regardless of
the selected image alias. Older output roots and their `C4_v3/` directories
are not automatically reused by this new tag.

Without a candidate filter, suite generation validates every configured
candidate, including C2, even though C2 has no independent measurement task.
Each alias must resolve to an existing config, FPGA image, manifest, and kernel
clock information. Use a new experiment tag when replacing a selected image.
See the subset workflow below when some images are not yet available.

## Generate the workload

The pipeline consumes generated workload indexes; it does not create them. Use a
new tag when replacing candidate images, and use that tag throughout:

```bash
cd analysis_workspace/latency_on_hw
export EXPERIMENT_TAG=C3_C4_v3_pipeline
export PYTHON=$HOME/.conda/envs/vortex/bin/python
./make_case.sh full
```

`make_case.sh quick` generates a smaller workload; pass `--suite-size quick` to
the pipeline. Configure `build_latency_llama2` and `build_latency_llama3` once
before hardware execution:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

Run that command from each build directory. Hardware stages use the existing
Slurm allocation and `ci/run_black.sh hw`, with the selected alias config and no
extra compile defines.

## Run and resume the full pipeline

The supported sequence is `run -> refine -> compose -> prepare -> plot`:

```bash
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full
```

Every task has a versioned receipt under
`pipeline_state.<tag>/receipts/`. Attempt stdout and stderr are under
`pipeline_state.<tag>/attempts/`. A task is reused only when its inputs, options,
receipt, and complete output manifest still agree. Completed model, source, and
figure tasks survive a later sibling failure.

Inspect the plan without creating files, taking locks, programming the FPGA, or
running stage commands:

```bash
"$PYTHON" workflow.py status --tag "$EXPERIMENT_TAG"
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --dry-run
```

Resume a bounded stage range when its excluded prerequisites are valid:

```bash
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --from refine --to plot
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --from compose --to plot
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" \
  --from compose --to plot --rerun compose
```

`--rerun STAGE` re-enters only that stage and keeps its normal fine-grained
reuse rules. It does not force FPGA remeasurement. A range never runs an earlier
stage implicitly; missing or stale prerequisites stop with a recovery command.
There is intentionally no pipeline force flag for physical remeasurement. Use
the standalone measurement command only after every pipeline and legacy writer
for the same raw output root is quiescent.

Historical results without pipeline receipts can be adopted when the raw rows
and saved manifests prove the requested latency, power, xclbin, config, clock,
and acquisition settings. If only the historical application-source identity is
missing, opt in with `--adopt-legacy`; this flag does not waive missing metrics,
insufficient power samples, a conflicting SHA/config, or contradictory settings.
The original evidence remains referenced by the adoption receipt.

Refinement checkpoints each probe before execution and restore completed probes,
promotions, iteration budgets, and terminal outcomes after interruption. Normal
bounded operation reports `converged`, `no_candidates`, `budget_exhausted`, or
`unbracketed`. The latter two are accuracy outcomes, not process failures. Add
`--require-convergence` to allow downstream stages only for `converged` or
`no_candidates`; changing this gate does not launch more probes.

## Output and power provenance

The tagged roots are:

- `outputs_llama2_main.<tag>` and `outputs_llama3_main.<tag>` for measurements
  and refinement checkpoints
- `composed_results.<tag>` for per-model and combined composition
- `figure_prepare.<tag>` for model inputs to rendering
- `figure_output.<tag>` for validated figures and plot data

The pipeline passes the current tag's C1/C3/C4 raw databases and captured
candidate snapshot explicitly to the `kernel_dynamic_power` plot. The plot
filters rows by that snapshot before aggregating them, so historical raw roots
beside the current experiment cannot enter TOPS/W or power figures. Plot receipts
record the consumed raw content.

Source suites, candidate configuration, and small indexes stay in YAML. Expanded
per-app suites, merged suites, and run snapshots use trusted local PKL by default.
Do not load downloaded pickle files. Use `--output-format yaml` with
`make_cases.sh` only for an explicit YAML export. Indexes select active payloads,
so stale YAML/PKL siblings are not rediscovered.

Raw CSVs retain the actual execution label, alias, bin path, xclbin SHA-256,
selection digest, captured period, and clock source. A logical C2 vector use is
therefore recorded with C1 as its physical source. Composition keeps expected
image identity and actual source provenance; prepared totals retain aggregated
provenance.

## Slurm campaign wrapper

`agent-tasks/latency_on_hw-refine/run_campaign.sh` only establishes the repository
and allocation environment, writes `campaign_status.json`, and enters
`workflow.py pipeline`. Pass range, rerun, adoption, or convergence flags as
wrapper arguments; set the tag and suite size through `EXPERIMENT_TAG` and
`SUITE_SIZE`. It resolves the repository from `SLURM_SUBMIT_DIR` because Slurm
executes a copied script from its spool directory.

Do not start this wrapper against an output root still owned by an older shell
campaign. The pipeline detects its `latest/run_state.json` writer and blocks.
After the old writer is quiescent, inspect `status` or `--dry-run`; adopt only
complete compatible evidence, then start the successor from the first reported
pending stage.

## Measure a subset of candidates

Use `--candidates C1` or a comma-separated list such as `--candidates C1,C3`
with `workflow.py pipeline` or `status`. It selects physical execution sources,
not logical model variants. C2 has no independent measurement; selecting C2
directly is an error. `--candidates C1` collects TCU GEMM and all vector/layout/
quantization kernels; `--candidates C4` collects the improved GEMM kernels.
The complete logical C1 workload now executes on C1. The downstream pipeline
still produces the full candidate comparison and therefore requires C3/C4.
Regenerate suites after this routing change: existing generated suites and raw
rows keep their original hardware provenance. Historical C4 vector timings are
not relabeled or reused as C1 measurements.

| Phase | Candidate subset behavior |
| --- | --- |
| `run` | Measures latency and power only for the selected execution sources. |
| `refine` | Refines selected sources independently, requiring their compatible run evidence. Probes measure latency only. |
| `compose` | Requires C1/C3/C4 raw databases, full generated workloads, and compatible run/refine evidence for all sources. |
| `prepare` | Uses complete composed results; the pipeline validates the full upstream chain. The candidate filter does not trim figures or models. |
| `plot` | Uses prepared results plus C1/C3/C4 raw databases for kernel power, and validates the full upstream chain. |

The default execution selection remains C1,C3,C4. Missing downstream raw files
produce an error naming the source and exact `raw_db.csv` path. A subset
selection never silently omits missing sources from composition or plots.
When a range includes downstream stages, the selected run/refine work completes
before the full-source barrier is checked. Existing compatible evidence for
unselected sources can satisfy that barrier.

Generate suites for the same subset when other images are not available:

```bash
cd analysis_workspace/latency_on_hw
export PYTHON=$HOME/.conda/envs/vortex/bin/python
export EXPERIMENT_TAG=C1_rev3_initial
CANDIDATES=C1 ./make_case.sh full
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full \
  --candidates C1 --to run --dry-run
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full \
  --candidates C1 --to run
```

`make_cases.sh` also accepts `--candidates C1` directly. Only selected aliases
are resolved; unselected map entries may be absent, `null`, or `none`. Selected
entries still require real image/config/manifest/clock artifacts. Generation
collects the selected source's cases across all logical workload variants and
keeps only those sources in the merged indexes. Empty per-variant indexes are
marked explicitly and skipped by the merger.

Results are `outputs_llama2_main.<tag>/C1/raw_db.csv` and
`outputs_llama3_main.<tag>/C1/raw_db.csv`. Use `--to refine` to include refinement,
or `--from refine --to refine --candidates C1` to refine existing C1 results.
Hardware execution still requires configured build directories and the normal
Slurm environment. Neither `--dry-run` nor `status` starts hardware work.

Partial snapshots use schema version 2; historical full snapshots remain
supported. Adding unrelated aliases does not invalidate an existing partial
snapshot, but changing a selected image/config does. An explicitly filtered
experiment can be extended under the same tag by regenerating with a superset,
for example `CANDIDATES=C1,C3,C4 ./make_case.sh full`, as long as all previously
captured candidate artifacts are unchanged. Rerun the pipeline with all sources;
compatible C1 raw rows are adopted through the existing strict measurement
checks, and missing sources are measured. Removing candidates or changing an
existing selection still requires a new tag. Power plots use the generated workload
snapshot when present, so a reused C1 manifest with a partial snapshot cannot
exclude C3/C4 rows from a full plot.
