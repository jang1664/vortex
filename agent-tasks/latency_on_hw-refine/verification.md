# Implementation and verification

Updated: 2026-09-18, KST.

## Delivered behavior

- `analysis_workspace/latency_on_hw/candidate_fpga_bins.yaml` selects the four requested aliases. C2 still reuses C1/C3/C4; no C2 execution group is generated.
- Generated suites capture a versioned experiment snapshot. Run preparation and queued job startup check that selection. Hardware wrapper calls use a run-local frozen alias table.
- Raw DBs record actual alias, existing bin path/SHA, selection digest, and captured clock. Composition filters by the snapshot's per-source SHA before deduplication. Power/latency estimation retains identity boundaries and source provenance.
- Expanded generated/merged suites and run snapshots use PKL. Small indexes and source configuration remain YAML. Atomic writes preserve previous payloads on write failure; index-driven discovery avoids stale YAML/PKL duplicates.
- The supported generation/run/compose/prepare examples share `EXPERIMENT_TAG`. Historical archives and global C1–C4 aliases were not changed.
- `workflow.py pipeline` now owns the ordered `run -> refine -> compose -> prepare -> plot` flow. Versioned receipts, strict measurement coverage, recoverable refinement checkpoints, isolated postprocessing attempts, and validated output manifests provide task-level resume.
- Stage ranges, stage rerun, read-only dry-run/status, explicit legacy adoption, and an optional strict convergence gate are exposed by the same entry point. C2 still creates no execution task.
- The campaign wrapper now contains allocation/repository setup and status reporting only, then delegates to `workflow.py pipeline`. It retains `SLURM_SUBMIT_DIR` handling for a copied Slurm script.

## Validation

The final selected fixture regression passed **221 tests** across the runner CLI,
candidate workflow, compose, interpolation, estimation, suite snapshots, merge,
strict raw-DB reuse, pipeline orchestration, prepared/rendered artifacts, energy
export, and no-area-normalization preparation. The run excluded three verified
pre-existing assertions: the generated progress-format expectation, the
single-device fake `xrt-smi` assumption on this multi-device host, and the
compact-layout `subplot_title_inside` expectation. No test accessed FPGA
hardware.

The completed code review confirmed five actionable findings. All five were
resolved: exact selected-model plot inputs, excluded-refinement receipt
compatibility, the legacy merged-YAML fallback, pinned warmup/iteration
acquisition settings, and linear raw-row indexing for strict reuse. The added
regressions are included in the 220-test run.

The focused verification command passed **89 tests**. It covers the new candidate workflow, suite snapshots, merge, composition, interpolation, estimation, the composed pipeline, energy export, and the legacy runner command ordering.

```bash
$HOME/.conda/envs/vortex/bin/python -m unittest \
  tools.latency_bench.test_cli_run.CliRunTest.test_run_blackbox_args_merge_into_generated_script \
  tools.latency_bench.test_candidate_workflow \
  tools.latency_bench.test_compose \
  tools.latency_bench.test_interpolation \
  tools.latency_bench.test_estimate \
  tools.latency_bench.test_suite_snapshots \
  tools.latency_bench.test_merge_suites \
  analysis_workspace.latency_on_hw.test_composed_pipeline \
  analysis_workspace.latency_on_hw.test_energy_per_token -q
```

Shell syntax checks and `git diff --check` passed. Llama2 quick prefill/generation dry runs emitted PKL snapshots and the requested C1/C3/C4 aliases. Both models' full generated group counts exactly match the previous workload's logical case counts and unique execution counts; see [generated_counts.json](generated_counts.json).

The U6 operational tests passed **46 pipeline tests**, including a copied Slurm
wrapper resolving the checkout through `SLURM_SUBMIT_DIR`, an actual legacy
`run_state.json` blocking every child command, and read-only planning preserving
the candidate file, global alias map, and source workload while planning only
C1/C3/C4. The expanded set also covers single-model plotting, compatible
excluded-refinement receipts, fixed acquisition environment, and legacy
YAML-only suite discovery. Python compilation for 25 changed files, shell syntax
for 11 changed scripts, and `git diff --check` passed.

The broad historical suite is not green on unmodified HEAD. An isolated HEAD
copy ran 234 tests with 11 failures and 17 errors, including stale plot fixtures
missing `exec_key`, a missing `plot_notebook.py`, old workload expectations, and
device-dependent runner failures. The final selected regression excludes three
unchanged mismatches: `test_programs_fpga_before_bench_run` assumes one visible
XRT device, the CLI test expects an obsolete progress-print format, and the
compact-layout test expects subplot titles inside although HEAD sets them
outside. No unrelated historical tests or RTL were changed to mask those
failures.

## PKL performance

Each storage operation was measured in a separate Python process using the existing C YAML loader/dumper as the baseline. Both formats reconstructed identical defaults, cases, experiment metadata, and execution counts. These are local single-run measurements, not a statistical performance guarantee.

| Input | Cases | YAML write | PKL write | YAML read | PKL read |
| --- | ---: | ---: | ---: | ---: | ---: |
| Quick generation C4 | 10,240 | 4.101 s | 0.038 s | 6.360 s | 0.032 s |
| Full generation C3 | 36,864 | 17.154 s | 0.589 s | 25.139 s | 0.354 s |

For the full input, read-process peak RSS fell from 1,812,060 KiB to 303,360 KiB. File size fell from 42,983,660 to 39,821,809 bytes. The principal improvement is serialization/load time and memory, rather than compression. Model expansion, model-structure dumps, and hardware execution are separate costs; this storage benchmark does not claim to accelerate them.

Reproduction: [benchmark_storage.py](benchmark_storage.py). Raw measurements: [benchmark_full.json](benchmark_full.json), [benchmark_quick.json](benchmark_quick.json).

## Hardware verification and campaign

Configured fresh `build_latency_llama2` and `build_latency_llama3` directories with the required xlen64/tooldir/prefix settings. Smoke runs used the mapped configs, Slurm, and `ci/run_black.sh hw`, with GCC/G++ from `/usr/bin` and no extra compile defines.

All five smoke cases passed, with valid latency, cycle counts, and power samples:

| Source | App | Power samples |
| --- | --- | ---: |
| C1 | `sgemm_tcu` | 66 |
| C3 | `fpint_gemm_ffn_hw_naive` | 41 |
| C4 | `fpint_gemm_ffn_hw` | 43 |
| C4 | `eladd` | 5 |
| C4 | `rms_norm_layout_fused` | 129 |

Exact arguments, image identities, and measurements: [smoke_results.json](smoke_results.json). These small cases validate the workflow; they are not full-model performance results.

Full Llama2/Llama3 prefill and generation measurement completed under Slurm job
4935 with experiment tag `th16_20260917`. The six raw databases contain 2,124
passing, unique rows. Source reconciliation and the value audit are recorded in
[raw-db-audit-20260918.md](raw-db-audit-20260918.md).

Output roots:

- `analysis_workspace/latency_on_hw/outputs_llama2_main.th16_20260917`
- `analysis_workspace/latency_on_hw/outputs_llama3_main.th16_20260917`
- `analysis_workspace/latency_on_hw/composed_results.th16_20260917`
- `analysis_workspace/latency_on_hw/figure_prepare.th16_20260917`
- `analysis_workspace/latency_on_hw/figure_output.th16_20260917`

The first campaign submission, job 4934, exited before measurement because Slurm relocates submitted scripts. The script now resolves the repository from `SLURM_SUBMIT_DIR`; replacement job 4935 successfully started hardware measurement. No measurements were attributed to the failed submission.

### Read-only adoption audit

At 2026-09-17 19:41 KST, `squeue` reported job 4935 `RUNNING` on the
`fpga` partition with 5:27:57 elapsed and a two-day limit. The saved campaign
status reported `measure_llama2`. Llama2 C1 and C3 had completed run states and
30/30 passing rows each with finite cycle counts, positive power samples, one
captured alias, and one xclbin SHA. C4 had an active run state; at the audit
instant 167/177 rows passed with finite cycle counts and positive power samples.
The log was actively advancing through C4 cases. Llama3 had not started.

This audit was read-only: it did not write receipts, adopt rows, start a pipeline,
cancel/restart job 4935, or submit a successor. The active C4 writer means the
new pipeline correctly remains blocked even though the old campaign has no new
resource lock. Counts above are a point-in-time observation and are not a final
completeness claim.

Job 4935 runs Slurm's copied version of the former shell script, so editing the
checkout wrapper cannot add refinement or plotting to that allocation. Slurm
job **4936** is now pending on `afterany:4935`. After the legacy allocation ends,
it runs `workflow.py pipeline --tag th16_20260917 --suite-size full
--adopt-legacy`. Strict validation adopts compatible completed measurements,
runs missing work, and continues through refine, compose, prepare, and plot.
Using `afterany` also permits recovery if job 4935 fails or reaches its time
limit.

Job 4936 exposed an incorrect refinement checkpoint path and exited before doing
work. After that path was corrected, job 4937 reused all 12 compatible
measurement tasks, completed six refinement tasks, composed both models, and
prepared both model outputs. It then exposed a direct-script import failure in
the first plot task. Adding the repository root to `plot.py` fixed the failure;
48 focused regressions passed and a local `workflow.py pipeline --from plot
--to plot` resume completed all seven render tasks. The final figure root has 30
files, including seven validated render manifests. Llama2 and Llama3 C4 each
used three refinement iterations and converged for the three interpolated
physical kernel groups; C1 and C3 had no unresolved interpolation probes.
