# Latency Bench

`tools.latency_bench` runs FPGA benchmark binaries from `tests/regression/*/bench_main.cpp`,
aggregates their CSV output, and generates static PNG/PDF figures.

The runner is designed to be launched from the repository root while using a
configured build directory. It reuses the generated `build/ci/blackbox.sh` and
the existing `--bench` flow, so app-specific benchmark code remains in
`tests/regression/<app>/bench_main.cpp`.

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

## Suite Format

```yaml
name: llama2_7b_prefill_s128
defaults:
  warmup: 3
  iterations: 10
  app: fpint_gemm_ffn_hw
  target: hw
  platform: xilinx_u55c_gen3x16_xdma_3_202210_1
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

## Outputs

The output directory contains:

- `cases.csv`: expanded cases and deduplicated execution keys.
- `run_fpga_bench.sh`: generated shell script used for the run.
- `run_status.csv`: one row per unique execution.
- `raw/*.csv`: raw benchmark rows from `bench_util.h`.
- `logs/*.log`: per-execution blackbox logs.
- `results.csv`: one row per logical case with latency and metadata.
- `summary.csv`: calls-per-forward weighted total latency estimates.
- `figures/*.png` and `figures/*.pdf`: case latency, weighted breakdowns, and status summary.

In `summary.csv`, `weighted_total_avg_us` means
`sum(avg_us * calls_per_forward)` for the group, not an arithmetic mean.

## Visualize Existing Results

```bash
python -m tools.latency_bench visualize \
  --results results/latency/llama2_7b_prefill/results.csv \
  --out results/latency/llama2_7b_prefill/figures
```

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

Dry-run expands the suite and emits `run_fpga_bench.sh` without launching FPGA jobs.
