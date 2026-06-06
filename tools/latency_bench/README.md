# Latency Bench

`tools.latency_bench` runs FPGA benchmark binaries from `tests/regression/*/bench_main.cpp`,
aggregates their CSV output, and can generate static PNG/PDF figures.

The runner is designed to be launched from the repository root while using a
configured build directory. It reuses the generated `build/ci/blackbox.sh` and
the existing `--bench` flow, so app-specific benchmark code remains in
`tests/regression/<app>/bench_main.cpp`.

## Python Dependencies

Use the Vortex conda environment and install the analysis packages there:

```bash
conda activate vortex
python -m pip install pandas matplotlib pyyaml scikit-learn
```

Without activating the environment, run the same install through the explicit
environment Python:

```bash
$HOME/.conda/envs/vortex/bin/python -m pip install pandas matplotlib pyyaml scikit-learn
```

## How It Works

`latency_bench` is a thin orchestration layer around the existing Vortex
blackbox benchmark flow. It does not compile kernels or implement benchmark
logic itself. Its job is to expand a suite into concrete benchmark invocations,
generate a reproducible shell script, run `ci/blackbox.sh --bench`, and convert
the raw benchmark CSV files into analysis-friendly CSVs. Plot generation is
explicitly opt-in.

The main `run` flow is:

1. Load the suite YAML with `tools.latency_bench.suite.load_suite`.
2. Merge suite defaults with CLI overrides such as `--warmup` and `--iterations`.
3. Expand explicit `cases` directly into `BenchCase` objects.
4. Expand `workloads` through `tools/workload/gen_kernel_cfgs.py`; each
   implemented kernel with an app and args becomes a `BenchCase`.
5. Compute an `exec_key` for each unique `(app, args, warmup, iterations)` tuple.
   Multiple logical cases can share one physical FPGA execution when their
   benchmark command is identical.
6. Create a per-run directory under `<out>/runs/<run_id>`.
7. Write `cases.csv`, which records every logical case after expansion.
8. Copy the original suite to `suite.yaml` and write the expanded suite to
   `suite.expanded.yaml`.
9. Generate `run_fpga_bench.sh` in the per-run directory.
10. Run that script directly or through `srun`.
11. Build each unique benchmark app once with `blackbox.sh --build-only --bench`.
12. Run each unique execution with `blackbox.sh --run-only --bench`.
13. Append one row to `progress.csv` after each unique execution finishes.
14. Read `run_status.csv` and `raw/*.csv` to build `results.csv`.
15. Build `summary.csv` by applying `calls_per_forward` weights to successful
    rows in `results.csv`.
16. Append all `results.csv` rows to the top-level `<out>/raw_db.csv`.
17. Optionally call `visualize` to create figures under the per-run `figures/`.

The generated `run_fpga_bench.sh` is the source of truth for what actually ran.
For each unique execution it:

- Changes directory to `--build-dir`, because configured build outputs such as
  `ci/blackbox.sh`, generated Makefiles, and app build trees live there.
- Exports FPGA runtime environment variables: `FPGA_BIN_DIR`, `TARGET=hw`,
  `PLATFORM`, `DRIVER=xrt`, and `XRT_DEVICE_INDEX`.
- Calls `./ci/blackbox.sh --driver=xrt --bench --build-only --app=<app>`
  once per app, then `./ci/blackbox.sh --driver=xrt --bench --run-only`
  for each concrete execution.
- Passes benchmark-specific args including `--warmup`, `--iterations`, `--csv`,
  and `--output=<out>/runs/<run_id>/raw/<exec_key>.csv`.
- Records one status row in `run_status.csv` with `exec_key`, `app`,
  `returncode`, `failure_phase`, `failure_reason`, `raw_csv`, `log_file`, and
  `elapsed_wall_s`.
- Appends one live progress row to `progress.csv` with status, elapsed time,
  raw latency columns, and parse errors.

`results.csv` is case-oriented, not execution-oriented. If two logical cases
share the same `exec_key`, they reuse the same raw benchmark measurement but
keep their own `case_id`, `kind`, `stage`, `name`, `shape_json`, and
`calls_per_forward` metadata. Workload-generated cases also record `op`,
`backend`, and `variant`: `op` is the model operation, `kind` is the logical
compute family, `backend` is the implementation/argument convention, and `app`
is the benchmark executable passed to blackbox. `summary.csv` is derived from
`results.csv`; it groups successful rows by stage, kind, backend, op, kernel
name, and total suite latency.

The top-level `raw_db.csv` is append-only. Reusing the same `--out` across
multiple days preserves every measurement row, including repeated measurements
of the same `(FPGA bin, app, args, warmup, iterations)` tuple. Aggregate or
interpolate from this DB in a later analysis step instead of overwriting older
measurements.

## Launch Location

The Python module is stored in the source tree under `tools/latency_bench`.
Running `python -m tools.latency_bench ...` requires the source tree to be on
Python's module search path. The simplest supported invocation is from the
repository root with `--build-dir build`.

When launching from a configured build directory, either add the source root to
`PYTHONPATH` or invoke Python from the source root. For example:

```bash
cd build
PYTHONPATH=.. python -m tools.latency_bench run \
  --build-dir . \
  --fpga-bin improve_tcol1 \
  --suite ../tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out results/latency/llama2_7b_prefill \
  --warmup 3 \
  --iterations 10
```

## Run

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --fpga-bin /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_noDcache_L2cache_a917286dbe/bin \
  --suite tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out results/latency/llama2_7b_prefill \
  --warmup 3 \
  --iterations 10
```

By default, the tool wraps the generated run script in:

```bash
srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=01:00:00
```

Use `--no-srun` only when already running on an FPGA host with XRT access.

If the FPGA bin path is too long to type repeatedly, add or update an entry in
`ci/fpga_bin_alias_map.yaml` and pass the alias name to `--fpga-bin`. The same
alias map is used by `python -m tools.latency_bench run` and
`ci/run_black.sh`. Set `VORTEX_FPGA_BIN_ALIAS_MAP=/path/to/map.yaml` to test a
local alias map without editing the repository copy.

`--fpga-bin` can be omitted when the suite sets `defaults.fpga_bin`. Passing
`--fpga-bin` on the CLI still wins over the suite default.

FPGA bin aliases may also name a config script through the alias map `configs`
field. `latency_bench` sources that script before appending `--configs-extra`.
The built-in aliases source files under `configs/`, including per-alias improve
configs.

`--blackbox-arg` starts from suite `defaults.blackbox_args`; repeated CLI values
add new options or overwrite existing options with the same flag key. For
example, `--blackbox-arg=--threads=16` replaces a default `--threads=8` while
keeping other defaults such as `--cores=1`.

Use `--blackbox-timeout 30m` to wrap each `blackbox.sh` execution with GNU
`timeout --kill-after=30s`. With the default prebuild flow, this
timeout wraps only the run-only benchmark execution, not the build-only
preflight. A timed-out execution records its return code in `run_status.csv`,
then the run script attempts to clean up stale benchmark processes tied to that
case's raw CSV path before continuing. Set `defaults.blackbox_timeout` in the
suite to make this reproducible, or pass `--blackbox-timeout 0` to disable a
suite default.

Use `--filter` to run only a subset of expanded suite cases without editing the
suite YAML:

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --suite tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out results/latency/prefill_gemm_only \
  --filter "app=fpint_gemm_ffn_hw & stage=prefill"
```

Filters are evaluated after explicit cases, `case_matrices`, and `workloads`
are expanded into `BenchCase` objects. Supported operators are exact equality
`=`, inequality `!=`, glob match `=~`, glob mismatch `!~`, AND `&`, OR `|`,
NOT `!`, and parentheses. Supported fields are `id`/`case_id`, `app`, `args`,
`kind`, `op`, `backend`, `variant`, `stage`, `name`, `calls_per_forward`,
`warmup`, `iterations`, `source`, `fpga_bin`, and `shape.<key>`. Repeating
`--filter` ANDs the expressions.

Transient XRT context-open failures are retried within the same execution. If a
run log contains `failed to open cu context`, the generated script retries that
case up to two more times with short backoff. Persistent failures are recorded
with `failure_reason=xrt_context_open`.

The default prebuild flow separates build failures from benchmark failures.
If a benchmark app fails to build, all executions for that app are recorded as
`status=build_fail` with `failure_phase=build` and `failure_reason=build`, and
the per-case log points at the captured build output. Use `--no-prebuild` only
when you intentionally want the legacy build-and-run behavior inside each
benchmark invocation.

`run` does not generate figures by default. Add `--visualize` to create
`runs/<run_id>/figures/` after a successful run, or use the `visualize`
subcommand later.

## Suite Format

```yaml
name: llama2_7b_prefill_s128
defaults:
  warmup: 3
  iterations: 10
  app: fpint_gemm_ffn_hw
  fpga_bin: improve_tcol1
  target: hw
  platform: xilinx_u55c_gen3x16_xdma_3_202210_1
  blackbox_timeout: 30m
  blackbox_args:
    - --cores=1
    - --threads=8
cases:
  - id: q_proj_s128
    app: fpint_gemm_ffn_hw
    kind: gemm
    op: q_proj
    backend: fpint_gemm_improve
    variant: all_fpint_gemm_improve
    stage: prefill
    name: q_proj
    args: "-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0"
    calls_per_forward: 32
workloads:
  - id: llama2_7b_prefill_s128
    model: llama2-7b
    stage: prefill
    variant: attn_sgemm_tcu_fpint_gemm_naive
    prefill_seq_len: 128
    qblk: 32
    implemented_only: true
fpga_bins:
  default: naive
  by_backend:
    fpint_gemm_improve: improve_tcol32
    sgemm_tcu: base_t8
  by_app:
    silu_layout_fused: improve_tcol1
```

`workloads` are expanded through `tools/workload/gen_kernel_cfgs.py`. Each
implemented kernel with an app and argument string becomes a benchmark case.
The supported workload variants are `all_fpint_gemm_naive`,
`attn_sgemm_tcu_fpint_gemm_naive`, `all_fpint_gemm_improve`,
`attn_sgemm_tcu_fpint_gemm_improve`, `all_sgemm_tcu`,
`all_fpint_gemm_improve_alone_layout`, and
`all_fpint_gemm_improve_fused_layout`.
Workload entries can also define a `matrix`; its keys are overlaid onto the
workload before expansion, so the same workload template can sweep batch,
sequence length, QBLK, or filters:

```yaml
workloads:
  - id: llama2_7b_prefill
    model: llama2-7b
    stage: prefill
    filter_kind: rmsnorm
    matrix:
      batch: {values: [1, 8]}
      prefill_seq_len: {pow: [128, 1024]}
      qblk: 32
```

Use `filter_kind: gemm` for logical GEMM operations regardless of backend, or
`filter_backend: fpint_gemm_naive`, `filter_backend: fpint_gemm_improve`, or
`filter_backend: sgemm_tcu` for implementation-specific filtering.

For regular parameter sweeps, use `case_matrices` instead of writing every case
by hand. Each matrix key can be a scalar, a `values` list, or an inclusive
power-of-two range. Use either `pow` or `pow2` for the range key:

```yaml
case_matrices:
  - id: fpint_gemm
    kind: gemm
    backend: fpint_gemm_improve
    stage: sweep
    name: fpint_gemm_m{m}_n{n}_k{k}
    args: "-m {m} -n {n} -k {k} -q {qblk} -t {wtrans} -d {qdir}"
    matrix:
      m: {pow2: [1, 128]}
      n: {pow2: [128, 4096]}
      k: {pow2: [128, 4096]}
      qblk: 32
      wtrans: 0
      qdir: 0
    shape:
      M: "{m}"
      N: "{n}"
      K: "{k}"
      QBLK: "{qblk}"
      WTRANS: "{wtrans}"
      QDIR: "{qdir}"
```

This expands to the Cartesian product of all matrix values. The example above
creates `8 * 6 * 6 = 288` cases. Use `--dry-run` and inspect
`suite.expanded.yaml` to see the explicit cases before running on FPGA.

## Generate Suites

Use `generate-suites` to start from one mixed workload suite and export one
runnable suite per `(app, FPGA bin)` group:

```bash
python -m tools.latency_bench generate-suites \
  --suite tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out results/latency/generated_suites
```

The generator expands `cases`, `case_matrices`, and `workloads`, resolves the
FPGA bin for each expanded case, then writes explicit generated suites plus an
`index.yaml`. The FPGA bin precedence is:

- Case-level `fpga_bin`.
- `fpga_bins.by_app[case.app]`.
- `fpga_bins.by_backend[case.backend]`.
- `fpga_bins.by_kind[case.kind]` or the compatible `by_kernel`/`kernels` keys.
- `fpga_bins.default`.
- `defaults.fpga_bin`.

Each generated suite sets `defaults.fpga_bin`, so it can be launched without
repeating `--fpga-bin`:

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --suite results/latency/generated_suites/<suite>.yaml \
  --out results/latency/<suite>
```

Existing generated files are not overwritten unless `--overwrite` is passed.

## Merge Suites

Use `merge-suites` to combine generated suite YAMLs and avoid rerunning
identical executions. A duplicate is the same FPGA alias plus the same app,
arguments, warmup, and iteration count.

```bash
python -m tools.latency_bench merge-suites \
  --suite-glob "analysis_workspace/latency_on_hw/generated_suites/C*_prefill/*.yaml" \
  --out analysis_workspace/latency_on_hw/generated_suites/merged \
  --group-by-fpga-bin \
  --overwrite
```

With `--group-by-fpga-bin`, `--out` is a directory and the command writes one
runnable suite per FPGA bin plus an `index.yaml`. Without it, all inputs must
resolve to one FPGA bin and `--out` is the output YAML file.

## Outputs

The output root contains:

- `raw_db.csv`: append-only measurement DB across all runs that reuse this `--out`.
- `runs/<run_id>/`: immutable-ish artifact directory for one invocation.

Each `runs/<run_id>/` directory contains:

- `cases.csv`: expanded cases and deduplicated execution keys.
- `suite.yaml`: copy of the original suite YAML used for the run.
- `suite.expanded.yaml`: equivalent suite with all `workloads` materialized as explicit `cases`.
- `run_fpga_bench.sh`: generated shell script used for the run.
- `run_status.csv`: one row per unique execution, including `failure_phase` and
  `failure_reason`.
- `progress.csv`: live per-execution results appended as each benchmark finishes.
- `raw/*.csv`: raw benchmark rows from `bench_util.h`.
- `logs/*.log`: per-execution blackbox logs.
- `results.csv`: one row per logical case with latency and metadata.
- `summary.csv`: calls-per-forward weighted total latency estimates.
- `figures/*.png` and `figures/*.pdf`: optional output created by `run --visualize`
  or the `visualize` subcommand.

In `summary.csv`, `weighted_total_avg_us` means
`sum(avg_us * calls_per_forward)` for the group, not an arithmetic mean.

## Append-Only Raw DB

By default, every non-dry run appends its `results.csv` rows to
`<out>/raw_db.csv`. Reuse the same `--out` for the same long-lived measurement
DB:

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --fpga-bin /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_noDcache_L2cache_a917286dbe/bin \
  --suite tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out results/latency/improve_tcol1-fpint_gemm_hw
```

Use `--skip-existing` when resuming a long-running sweep and you only want to
retry missing or failed executions:

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --fpga-bin improve_tcol1 \
  --suite tools/latency_bench/suites/llama2_7b_layout_fused_seq_sweep.yaml \
  --out results/latency/improve_tcol1-llama2_7b_layout_fused_seq_sweep \
  --skip-existing
```

An execution is skipped only when `<out>/raw_db.csv` already has a `status=pass`
row whose `fpga_bin_label`, `xclbin_sha256`, `exec_key`, `app`, normalized
`args`, `warmup`, and `iterations` all match the current run. `build_fail`,
`fail`, `timeout`, `parse_error`, and `not_run` rows are not skipped, so they
are retried.
When a retried execution writes a new row, any older `raw_db.csv` rows with the
same strict match key are replaced by the new result. Skipped `pass` executions
are not appended back into `raw_db.csv`.

`raw_db.csv` includes run metadata (`run_id`, `fpga_bin_label`, `git_commit`,
`git_branch`, `git_dirty`, `fpga_bin_dir`, `xclbin_sha256`, `suite`,
`case_id`, `exec_key`, `app`, `args`, `shape_json`) plus benchmark status and
latency columns. Set `--run-id` or `LATENCY_BENCH_RUN_ID` to control the run
directory name; otherwise the CLI uses a UTC timestamp.

## Visualize Existing Results

Use the legacy per-run visualizer for one `results.csv`:

```bash
python -m tools.latency_bench visualize \
  --results results/latency/llama2_7b_prefill/runs/<run_id>/results.csv \
  --out results/latency/llama2_7b_prefill/runs/<run_id>/figures
```

Use suite/raw DB visualization to compose model-level latency from one or more
suites and one or more append-only raw DBs, then render grouped bar charts:

```bash
python -m tools.latency_bench visualize \
  --suite analysis_workspace/latency_on_hw/outputs_example/suite_example.yaml \
  --raw-db analysis_workspace/latency_on_hw/outputs_example/raw_db.csv \
  --out analysis_workspace/latency_on_hw/outputs_example/figures \
  --x seq_len \
  --hue variant \
  --row stage \
  --col batch \
  --stack-by name
```

The suite/raw DB mode expands the input suites, matches passing raw DB rows by
`app`, normalized `args`, and the case's resolved `fpga_bin_label`, applies
`calls_per_forward`, and writes
`composed_cases.csv`, `plot_data.csv`, `plot_stack_data.csv`,
`bar_total_<metric>.png`, and `bar_total_<metric>.pdf`. The default plot layout
is `x=seq_len`, `hue=variant`, `row=stage`, and `col=batch`. Any of those axes
can be changed with `--x`, `--hue`, `--row`, and `--col`; use `none` for
optional axes except `--x`.

`--stacked` is enabled by default and stacks the suite cases that make up each
bar, so a model/workload bar can show the latency contribution of kernels or
workload components. `--stack-by` selects the segment label from `name`,
`case_id`, `kind`, `backend`, `op`, or `app`; the default is `name`. Use
`--no-stacked` to draw only one total bar per axis/hue group. Use `--relative`
to normalize plotted bar totals so the smallest positive total is `1.0`; stacked
segments use the same baseline, so each stack still sums to the relative total.
`--relative-scope` controls where that baseline is selected: `global` preserves
the original whole-figure behavior, `subplot` normalizes independently per
subplot, and `x_tick` normalizes independently per x tick within each subplot.
Subplot y-axes are independent by default; add `--share-y` when panels should
use one shared y-axis scale. Use `--legend-position`, `--legend-ncol`,
`--figure-title`, `--x-label`, `--y-label`, and `--legend-title` to adjust
presentation without changing the raw DB data. Use `--value-order` to control
axis value order, for example `--value-order variant=C1,C2,C3,C4_fused`; values
not listed in the explicit order are appended using the default sort.

Use original workload suites for model-level comparisons; generated/merged
suites are execution shards split by FPGA bin. By default, `compose` and
`visualize` resolve each suite case through `fpga_bins` and only use raw DB rows
from that `fpga_bin_label`, so measurements from different FPGA binaries are not
mixed when `app` and `args` are identical. Add `--no-match-fpga-bin` only for
legacy raw DBs that do not carry `fpga_bin_label`.

Repeated raw DB measurements use `--select median` by default. Missing suite
cases use `--missing nan` by default so partially completed hardware sweeps can
still be inspected; missing cases are counted in `plot_data.csv` and annotated
on the affected bars. Use `--missing error` for strict final reporting.

## Compose Latency From Raw DB

Use `compose` to estimate a suite or workload latency from existing
`raw_db.csv` measurements without launching FPGA jobs:

```bash
python -m tools.latency_bench compose \
  --suite tools/latency_bench/suites/llama2_7b_prefill_s1024_b8.yaml \
  --raw-db /home/jaeyongjang/project.local/latency_db/fpint_gemm_hw/raw_db.csv \
  --fpga-bin-label improve_tcol1 \
  --metric p50_us \
  --out results/latency/composed/llama2_7b_prefill_s1024_b8
```

`compose` expands the suite with the same loader used by `run`, including
`cases`, `case_matrices`, and `workloads`. Each expanded case is matched against
passing raw DB rows by `app` and normalized `args`; `case_id` and `name` are not
used as lookup keys.

If multiple rows match one case, `--select median` is the default. Other
policies are `latest`, `mean`, `min`, and `strict`. Missing measurements fail by
default with `--missing error`; use `--missing nan` or `--missing skip` only
when intentionally producing a partial composition.

When `--out` is a directory, `compose` writes:

- `composed.csv`: one row per expanded case with selected latency,
  `weighted_latency_us`, `match_count`, and source run metadata.
- `summary.csv`: total composed latency for the selected metric.

When `--out` ends in `.csv`, only that composed case CSV is written.

## Compare Candidates

Use `compare` after running the same suite on multiple FPGA binaries or
branches. Candidate order is the command-line order.

```bash
python -m tools.latency_bench compare \
  --candidate C1=results/latency/c1 \
  --candidate C2=results/latency/c2 \
  --candidate C3=results/latency/c3 \
  --candidate C4=results/latency/c4 \
  --out results/latency/compare_c1_c2_c3_c4
```

Each candidate path can be a run output directory, `results.csv`, or
`summary.csv`. The comparison output contains:

- `merged_results.csv`: all candidate `results.csv` rows with `candidate`.
- `merged_summary.csv`: all candidate `summary.csv` rows with `candidate`.
- `compare_total.csv`: total latency per candidate and `relative_to_best`.
- `compare_kernel.csv`: kernel contribution per candidate.
- `compare_kernel_plot.csv`: the component table actually used for stacked plots.
- `figures/total_latency_p50.{png,pdf}`: one total bar per candidate.
- `figures/total_latency_p50_relative.{png,pdf}`: total bars normalized to the fastest candidate.
- `figures/kernel_stacked_latency_p50.{png,pdf}`: kernel breakdown stacked bars.
- `figures/kernel_stacked_latency_p50_relative.{png,pdf}`: stacked bars normalized by the fastest total.

The relative total is `candidate_total / min(candidate_total)`, so the fastest
candidate is `1.0`. For the relative stacked chart, each kernel contribution is
divided by the same fastest total, so the best candidate's full stack sums to
`1.0`.

## Dry Run

```bash
python -m tools.latency_bench run \
  --build-dir build \
  --fpga-bin /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_noDcache_L2cache_a917286dbe/bin \
  --suite tools/latency_bench/suites/llama2_7b_prefill.yaml \
  --out /tmp/vortex_latency_dry_run \
  --dry-run
```

Dry-run creates `runs/<run_id>/`, expands the suite, and emits
`run_fpga_bench.sh` without launching FPGA jobs or appending `raw_db.csv`. Use
it to inspect `cases.csv` and `suite.expanded.yaml` before spending FPGA time on
the run.
