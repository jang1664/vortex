# Head Concat GQA Benchmark Specification

## Goal

Correct the standalone `head_concat_layout_fused` latency benchmark so that
Llama3 decode measures the actual grouped PV layout: 32 query heads, 8 KV
heads, and 4 query-head rows per KV-head matrix.

## Scope

- `tools/workload/gen_kernel_cfgs.py`
- `tools/workload/test_kernel_variants.py`
- `tests/regression/head_concat_layout_fused/bench_main.cpp`
- Focused workload-generator and regression-app verification
- C4 hardware comparison of normal `head_concat` against corrected
  `head_concat_layout_fused`

## Design decisions

- Keep the semantic `heads=32` argument unchanged.
- Add `-query-heads-per-kv 4` to the fused Llama3 generation command line.
- Parse and validate the argument in the latency benchmark.
- Derive grouped input rows, padded rows, matrix count, and allocation size
  using `query_heads_per_kv`.
- Preserve `query_heads_per_kv=1` for Llama2 and prefill workloads.
- Do not change the device kernel or the regular row-major `head_concat` app.

## Constraints and assumptions

- The device kernel and correctness regression already implement grouped GQA.
- Hardware measurements use the configured C4 build and `ci/run_black.sh hw`.
- Existing unrelated worktree changes must be preserved.

## Final agreed specification

Confirmed by the user on 2026-07-31: implement the benchmark correction and
remeasure standalone versus fused.
