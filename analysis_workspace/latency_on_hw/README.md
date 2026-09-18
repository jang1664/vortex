# Llama hardware latency and power measurements

`candidate_fpga_bins.yaml` selects the C1–C4 aliases from
`ci/fpga_bin_alias_map.yaml`. The workflow does not change the global C1–C4
aliases. C2 keeps its existing composition: TCU GEMM comes from C1, naive GEMM
from C3, and vector kernels from C4. Registering a C2 image never creates a C2
measurement or refinement task. C4_fused remains included and C4_alone remains
excluded.

## Generate the workload

The pipeline consumes generated workload indexes; it does not create them. Use a
new tag whenever the candidate selection changes, and use that tag throughout:

```bash
cd analysis_workspace/latency_on_hw
export EXPERIMENT_TAG=th16_20260917
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
therefore recorded with C4 as its physical source. Composition keeps expected
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
