# Latency Bench

`tools.latency_bench` runs FPGA benchmark binaries from `tests/regression/*/bench_main.cpp`,
aggregates their CSV output, and can generate static PNG/PDF figures.

The runner is designed to be launched from the repository root while using a
configured build directory. It reuses the generated `build/ci/blackbox.sh` and
the existing `--bench` flow, so app-specific benchmark code remains in
`tests/regression/<app>/bench_main.cpp`.

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
11. Read `run_status.csv` and `raw/*.csv` to build `results.csv`.
12. Build `summary.csv` by applying `calls_per_forward` weights to successful
    rows in `results.csv`.
13. Append all `results.csv` rows to the top-level `<out>/raw_db.csv`.
14. Optionally call `visualize` to create figures under the per-run `figures/`.

The generated `run_fpga_bench.sh` is the source of truth for what actually ran.
For each unique execution it:

- Changes directory to `--build-dir`, because configured build outputs such as
  `ci/blackbox.sh`, generated Makefiles, and app build trees live there.
- Exports FPGA runtime environment variables: `FPGA_BIN_DIR`, `TARGET=hw`,
  `PLATFORM`, `DRIVER=xrt`, and `XRT_DEVICE_INDEX`.
- Calls `./ci/blackbox.sh --driver=xrt --bench --app=<app> --args=<bench args>`.
- Passes benchmark-specific args including `--warmup`, `--iterations`, `--csv`,
  and `--output=<out>/runs/<run_id>/raw/<exec_key>.csv`.
- Records one status row in `run_status.csv` with `exec_key`, `app`,
  `returncode`, `raw_csv`, and `log_file`.

`results.csv` is case-oriented, not execution-oriented. If two logical cases
share the same `exec_key`, they reuse the same raw benchmark measurement but
keep their own `case_id`, `kind`, `stage`, `name`, `shape_json`, and
`calls_per_forward` metadata. `summary.csv` is derived from `results.csv`; it
groups successful rows by stage, kind, kernel name, and total suite latency.

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

If the FPGA bin path is too long to type repeatedly, fill in the
`FPGA_BIN_ALIASES` skeleton in `tools/latency_bench/runner.py` and pass the
alias name to `--fpga-bin`.

`--blackbox-arg` starts from suite `defaults.blackbox_args`; repeated CLI values
add new options or overwrite existing options with the same flag key. For
example, `--blackbox-arg=--threads=16` replaces a default `--threads=8` while
keeping other defaults such as `--cores=1`.

Use `--blackbox-timeout 30m` to wrap each `blackbox.sh` execution with GNU
`timeout --foreground --kill-after=30s`. A timed-out execution records its
return code in `run_status.csv`, then the run script continues to the next case.
Set `defaults.blackbox_timeout` in the suite to make this reproducible, or pass
`--blackbox-timeout 0` to disable a suite default.

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
  target: hw
  platform: xilinx_u55c_gen3x16_xdma_3_202210_1
  blackbox_timeout: 30m
  blackbox_args:
    - --cores=1
    - --threads=8
cases:
  - id: q_proj_s128
    app: fpint_gemm_ffn_hw
    kind: fpint_gemm
    stage: prefill
    name: q_proj
    args: "-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0"
    calls_per_forward: 32
workloads:
  - id: llama2_7b_prefill_s128
    model: llama2-7b
    stage: prefill
    prefill_seq_len: 128
    qblk: 32
    implemented_only: true
```

`workloads` are expanded through `tools/workload/gen_kernel_cfgs.py`. Each
implemented kernel with an app and argument string becomes a benchmark case.

For regular parameter sweeps, use `case_matrices` instead of writing every case
by hand. Each matrix key can be a scalar, a `values` list, or an inclusive
power-of-two range:

```yaml
case_matrices:
  - id: fpint_gemm
    kind: fpint_gemm
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

## Outputs

The output root contains:

- `raw_db.csv`: append-only measurement DB across all runs that reuse this `--out`.
- `runs/<run_id>/`: immutable-ish artifact directory for one invocation.

Each `runs/<run_id>/` directory contains:

- `cases.csv`: expanded cases and deduplicated execution keys.
- `suite.yaml`: copy of the original suite YAML used for the run.
- `suite.expanded.yaml`: equivalent suite with all `workloads` materialized as explicit `cases`.
- `run_fpga_bench.sh`: generated shell script used for the run.
- `run_status.csv`: one row per unique execution.
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

`raw_db.csv` includes run metadata (`run_id`, `fpga_bin_label`, `git_commit`,
`git_branch`, `git_dirty`, `fpga_bin_dir`, `xclbin_sha256`, `suite`,
`case_id`, `exec_key`, `app`, `args`, `shape_json`) plus benchmark status and
latency columns. Set `--run-id` or `LATENCY_BENCH_RUN_ID` to control the run
directory name; otherwise the CLI uses a UTC timestamp.

## Visualize Existing Results

```bash
python -m tools.latency_bench visualize \
  --results results/latency/llama2_7b_prefill/runs/<run_id>/results.csv \
  --out results/latency/llama2_7b_prefill/runs/<run_id>/figures
```

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
