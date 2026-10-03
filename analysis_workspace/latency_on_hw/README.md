# Llama hardware latency and power measurements

`candidate_fpga_bins.yaml` selects the C1–C4 aliases from
`ci/fpga_bin_alias_map.yaml`. The workflow does not change the global C1–C4
aliases. TCU GEMM comes from C1, naive GEMM from C3, and improved GEMM from C4.
Plain vector, layout, and quantization kernels execute on C1. Layout-fused
kernels execute on C4, including fused Hadamard and KV-cache quantization.
Logical C2 combines C1 TCU/vector results with C3 naive GEMM results.
Registering a C2 image never creates a C2
measurement or refinement task. C4_fused remains included and C4_alone remains
excluded.

The local `candidate_fpga_bins.yaml` is the source of truth for image aliases.
Execution sources are C1, C3, and C4; logical C2 has no independent raw database.

## Kernel regression gate

Run the correctness and fused-overhead checks before starting a measurement
pipeline:

```bash
python3 ../../ci/test_llm_regression.py hw
python3 ../../ci/test_llm_regression.py hw --static-only
python3 ../../ci/test_llm_regression.py xrt-vcs-sim --apps 'softmax*'
```

The script tests the 22 measured applications with at least three shapes each
(76 correctness cases). Additional cases cover factor-172 Hadamard and the
actual tiled K/V quantization inputs, including a larger prefill shape.
TCU and standalone vector kernels use C1, fused vector kernels and improved
GEMM use C4, and naive GEMM uses C3. Defaults come from
`../candidates_fpga_utils/candidate_fpga_bins.yaml`. All hardware cases share one FPGA allocation;
candidate builds are isolated under `build_llm_regression/C1`, `C3`, and `C4`.
Before hardware allocation or simulation, the script compile-checks each
selected host and device source under its actual config. `--static-only` stops after these checks.
MXU-enabled LLM builds enforce `NUM_THREADS == MXU_ROW == MXU_COL` through
`static_assert`, with no whitelist of supported widths. C1 TCU/standalone
builds with GEMM disabled do not use the MXU and are exempt from that equality.
All selected correctness cases must pass before any benchmark starts.
Correctness uses the reference-checking host, then the nine standalone/fused
pairs are benchmarked on matched logical shapes (32 comparisons). Benchmark
cycles are the median of three measured iterations after one warmup. The
default overhead limit is 50% for general pairs and 30% for softmax and
quantization, including decode shapes. The bounds are inclusive.
`--max-overhead-pct`, `--softmax-max-overhead-pct`, and
`--quant-max-overhead-pct` override these limits independently.

`--config C1=ALIAS_OR_CONFIG_PATH` (repeat for C3/C4) overrides candidates.
An unqualified `--config ALIAS_OR_CONFIG_PATH` selects only its inferred
candidate. Hardware config paths must resolve to one registered image; if
multiple images share a config, select an alias explicitly. Simulation needs
only the config file. `--apps`, `--shapes`, `--candidates`, `--kernel-variant`,
`--timeout`, `--fail-fast`, `--list`, and `--dry-run` support focused checks.
`--case-file PATH` loads a JSON list of `Case` fields (`candidate`, `app`,
`shape`, `args`, optional `pair` and `bench_args`) to reproduce measured
pipeline inputs. Candidate routing remains enforced for these cases.
`--output` names a new result directory containing logs, CSV, JSON, and
`SUMMARY.md`; otherwise results go under `build_llm_regression/results/`.

Quantization checks packed weights, scales, and zero points exactly. The CPU
reference follows the selected kernel's FP16 or FP32 arithmetic; packed-output
mismatches are never waived.

Near-zero FP16 mismatches can receive `PASS_FP16_EXCEPTION` when both values
are at most 0.001 in magnitude, each failing comparison differs by at most 0.0001,
and every reported mismatch is accounted for (at most ten). NaNs, padding
corruption, row-sum errors, unreported mismatches, quantization errors, and
runtime failures cannot receive this exception. `--fp16-small-value 0` disables
it; `--fp16-abs-tol` adjusts its absolute error bound. Failed correctness prevents
speed approval for that pair. Filtered runs are marked `PARTIAL_PASS`, never a
full pipeline gate. During optimization, omit `--notify` and resolve failures locally.
Use `notify-me alarm -m "MESSAGE"` when work stops or needs user intervention.
The optional `--notify` flag sends one terminal gate-failure alarm with details.

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

The pipeline now starts with `generate`, followed by
`run -> refine -> compose -> prepare -> plot`. Generation calls the existing
`make_cases.sh` for the selected models and records its options, source identity,
candidate snapshot, and generated output contents in receipts. Use a new tag
when replacing candidate images:

```bash
cd analysis_workspace/latency_on_hw
export EXPERIMENT_TAG=th16_20261002_v2_pipeline
export PYTHON=$HOME/.conda/envs/vortex/bin/python
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full --to generate
```

`--suite-size quick` generates a smaller workload. `make_case.sh` remains a
compatibility entry for `workflow.py pipeline --from generate --to generate`.
Its three positional arguments map to `--suite-size`, `--decode-measurement`
(`exact`/`sampled`), and `--decode-sample-interval`. The defaults remain full/quick
presets, sampled decode, and interval 32.

The workflow also accepts the workload overrides supported by `make_cases.sh`:
`--batches`, `--seq-lens`, `--prefill-batches`, `--prefill-seq-lens`,
`--generation-batches`, `--generation-seq-lens`, `--generation-out-tokens`,
`--generation-max-seq-len`, `--candidate-map`, `--candidates`, and
`--output-format`. Routing overrides are `--fpga-bin-default` and repeatable
`--fpga-bin-remap`, `--fpga-bin-by-app`, `--fpga-bin-by-backend`, and
`--fpga-bin-by-kind`. Model input directories and generated output roots are
selected by `--workspace`, `--models`, `--suite-size`, and `--tag`.
Use the same generation options when resuming; changing them invalidates the
generation receipt.

Configure `build_latency_llama2` and `build_latency_llama3` once
before hardware execution:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

Run that command from each build directory. Start the workflow outside Slurm.
It rejects an existing `SLURM_JOB_ID`/`SLURM_STEP_ID`; internal model workers
receive the allocations created by the coordinator. Hardware stages use
`ci/run_black.sh hw`, with the selected alias config and no extra compile defines.

## Run and resume the full pipeline

The default sequence includes workload generation. Serial execution uses one
FPGA allocation for both models, processing each model's run and refinement
tasks in order:

```bash
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full \
  --model-execution serial
```

For concurrent models on two FPGA boards:

```bash
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" --suite-size full \
  --model-execution parallel --parallel-fallback error
```

The coordinator first counts free U55C GRES with sufficient CPU and memory on
usable nodes in the selected partition. If two slots are unavailable,
`--parallel-fallback error` stops before hardware execution;
`--parallel-fallback serial` switches to a single allocation. Availability is
checked again after generation. Actual allocation races stop after
`--allocation-wait` seconds rather than silently queueing indefinitely.

Each parallel worker requests one FPGA and owns it through all of its model's
prefill, generation, candidate, power, and refinement measurements. Serial mode
uses the same FPGA for both models. Generation, composition, preparation, and
plotting run on the host outside Slurm. Refinement requires hardware for its
additional probe shapes, so it shares the model's run allocation.

`--slurm-partition`, `--slurm-cpus`, `--slurm-mem`, `--slurm-time`, and
`--allocation-wait` control allocation requests. Defaults are `fpga`, 4 CPUs,
16G memory, seven days, and 30 seconds respectively. These flags apply only to
model measurement sessions. Do not wrap the top-level command in `srun` or
`sbatch`.

The board identity (`hostname` and user-function PCI BDF) is pinned per model in
`outputs_<model>_main.<tag>/model_fpga.json`, and historical run identity files
are checked too. A resume allocated a different board stops before measuring;
it cannot mix boards in one model's results. Successful historical rows without
run identity evidence are rejected too. The pin and model ownership follow the
result root even if `--state-root` changes. Use a new tag to measure on another
board. Fully completed measurement tasks reuse their receipts without acquiring
an FPGA. Session commands and logs are in
`pipeline_state.<tag>/model_sessions/<session-id>/`.

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

`--rerun` (or `--rerun run`) forces physical remeasurement in the run
stage. Other `--rerun STAGE` values re-enter that stage using its normal reuse
rules. A range never runs an earlier stage implicitly; missing or stale
prerequisites stop with a recovery command.

To replace measurements for selected applications and then rebuild figures:

```bash
"$PYTHON" workflow.py pipeline --tag "$EXPERIMENT_TAG" \
  --models llama2,llama3 --candidates C4 --from run --to plot \
  --rerun --adopt-legacy \
  --filter 'app=~kv_cache_quant_layout_fused* | app=softmax_layout_fused' \
  --kernel-variant kv_cache_quant_layout_fused_w4a16=prefill_tiled_chunk_fp32 \
  --kernel-variant softmax_layout_fused=rev2_shuffle_cursor
```

Filters use the existing case-expression syntax: `app=NAME`, `app=~GLOB`,
`&` for AND, and `|` for OR. Repeated `--filter` expressions are combined by
AND. The same filter limits refinement kernel types. Compose, prepare, and
plot still use the complete model workload and preserved measurements.
Historical measured probe points are included even if the current suite
marks those shapes as interpolated.

Repeat `--kernel-variant APP=NAME` to override each application's Makefile
selection. Without an override, the configured Makefile/environment selection
is retained and recorded. Each run stores `kernel_variants.json`, and its
manifest records the selected implementation, selection source, application
source hash, and `kernel.vxbin` SHA-256. The output root also indexes these
records by run ID; raw rows refer to that run ID.

Remeasurements are staged under `remeasurements/<stage>.<timestamp>/` with a
`raw_db.before.csv` backup and a `rerun_summary.json`. Only successful rows
replace the corresponding `(FPGA label, xclbin SHA, app, normalized args)`
entries. Failed and unselected rows are preserved. Benchmark success records
latency/power acquisition; it does not imply a value check. To resume after an
interruption, omit `--rerun`; strict reuse keeps completed measurements only
when implementation, hardware, clock, and acquisition evidence agree.
SIGTERM/keyboard interruption publishes completed rows when the process can
finish its handler; an immediate hard kill can leave evidence in staging.

Imported historical baselines may be explicitly sealed in a
`frozen_baseline.json` row-signature inventory. With `--adopt-legacy`, exact
unchanged rows for applications without an explicit variant override remain
available to the full-model composition. This preserves their original
source/variant provenance rather than claiming they were measured using the
current software. Hardware and acquisition checks still apply.

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

## Campaign wrapper

`agent-tasks/latency_on_hw-refine/run_campaign.sh` establishes the repository
and compiler environment, writes `campaign_status.json`, and enters
`workflow.py pipeline`. Pass range, rerun, adoption, or convergence flags as
wrapper arguments; set the tag and suite size through `EXPERIMENT_TAG` and
`SUITE_SIZE`. Run this wrapper from the host without a Slurm allocation as well;
the workflow owns model allocations.

Do not start this wrapper against an output root still owned by an older shell
campaign. The pipeline detects its `latest/run_state.json` writer and blocks.
After the old writer is quiescent, inspect `status` or `--dry-run`; adopt only
complete compatible evidence, then start the successor from the first reported
pending stage.

## Measure a subset of candidates

Use `--candidates C1` or a comma-separated list such as `--candidates C1,C3`
with `workflow.py pipeline` or `status`. It selects physical execution sources,
not logical model variants. C2 has no independent measurement; selecting C2
directly is an error. `--candidates C1` collects TCU GEMM and plain vector/layout/
quantization kernels; `--candidates C4` collects improved GEMM and layout-fused kernels.
The complete logical C1 workload now executes on C1. The downstream pipeline
still produces the full candidate comparison and therefore requires C3/C4.
Regenerate suites after this routing change: existing generated suites and raw
rows keep their original hardware provenance. Old C1 fused measurements remain
historical evidence; regenerated suites select C4 fused measurements for composition.

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
Hardware execution requires configured build directories and a working Slurm
installation. Launch the workflow without an allocation; it creates its own
model sessions. Neither `--dry-run` nor `status` starts hardware work.

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

Energy preparation and rendering produce four power modes for flat, stacked,
GEMM/layout/vector, and GEMM-only plots, with and without area normalization:

| `power_metric` | Kernel power used for energy | Dequantization discount |
| --- | --- | --- |
| `power_avg_W` | `power_pcie_avg_w` (measured board power) | None |
| `power_dynamic_avg_W` | `power_pcie_avg_w - power_idle_pcie_avg_w` for every kernel | Existing weight/KV rules |
| `power_fpga_avg_W` | Fixed FPGA idle + PCIe dynamic power for every kernel | None |
| `power_fpga_dequant_dynamic_W` | PCIe dynamic power for dequantization; fixed FPGA idle + PCIe dynamic power for other kernels | Existing weight/KV rules |

PCIe readings already represent board input power. VCC power is not added;
the historical `power_avg_w` and `power_dynamic_avg_w` columns are not used
to calculate these energy modes. Compose carries `power_idle_pcie_avg_w`
through measured, reused, and interpolated rows. Older composed CSVs without
this column must be rebuilt from raw measurements before energy preparation.

FPGA idle power uses `FPGA_IDLE_POWER` in `prepare.py`, currently
`0.854 * 6.300 + 0.852 * 0.200 = 5.5506 W`. Energy remains kernel FPGA time
times power, divided by the existing prefill/decode token count. The discount
scales dynamic dequantization energy by `0.48263` for weights and `0.28516`
for both K and V caches. Missing dynamic measurements remain missing in the
two new modes.

Rerun `prepare.py` on the composed CSV to create the new mode CSVs, then run
`plot.py` as usual; all four modes render by default with distinct filenames.
Image filenames for `power_fpga_avg_W` include `_fixed_idle` to identify the
constant idle baseline; the prepared CSV and CLI power-metric names stay the same.
To render just one of the new modes, from this directory:

```bash
"$HOME/.conda/envs/vortex/bin/python" plot.py \
  --plot llama_energy_no_area_norm_stacked --out-tokens 128 \
  --prepared-root "figure_prepare.<tag>" --out-dir "figure_output.<tag>" \
  --power-metric power_fpga_dequant_dynamic_W
```

### E2E figures with and without Hadamard

`plot.py --plot all` renders both versions of the default latency E2E figures,
with and without area normalization. Existing figure names include Hadamard;
the added directories and image names end in `_without_hadamard`.

The additional version excludes exactly the `hadamard` and
`hadamard_layout_fused` backends for every candidate before GEMM/vector/layout
aggregation. Layout overhead and E2E totals are recomputed from the remaining
kernels, then normalized to the remaining C4 total at each workload. Prepared
CSV inputs and the existing figures' calculations are preserved.

To render just the two versions without area normalization from this directory:

```bash
EXPERIMENT_TAG=th16_20260920_c4_slots16_v2r1
for PLOT in llama_e2e_no_area_norm_stacked llama_e2e_no_area_norm_stacked_without_hadamard; do
  "$HOME/.conda/envs/vortex/bin/python" plot.py \
    --plot "$PLOT" --out-tokens 128 --models llama2_7b,llama3_8b \
    --prepared-root "figure_prepare.${EXPERIMENT_TAG}" \
    --out-dir "figure_output.${EXPERIMENT_TAG}.hadamard_versions" \
    --formats png,pdf,svg
done
```

The area-normalized equivalents are
`llama_e2e_gemm_layout_vector_stacked` and
`llama_e2e_gemm_layout_vector_stacked_without_hadamard`. The workflow pipeline
tracks both versions using the same prepared inputs and separate render receipts.

### Skip a stalled application's power measurements

Add `--skip-power-app rope_layout_fused` to `workflow.py pipeline` to keep measuring
latency while omitting separate power repetitions for that app. The option is
repeatable and is also accepted by `tools.latency_bench run`. Other apps still
measure power. Compatible existing measurements, including measured power, are
reused. New latency-only rows have `measure_power=0`, blank power metrics, and
`power_source=skipped_stalled`; ordinary runs that require power cannot reuse
those rows without explicitly allowing this app to skip power. Energy summaries
with missing power are marked `complete=false`; they are partial results.
