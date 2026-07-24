# Vortex Regression Runner

This package discovers and runs functional tests under `tests/regression`.
Runnable tests must contain both `Makefile` and `main.cpp`.

## List tests

```bash
python -m tools.regression_runner list
python -m tools.regression_runner list \
  --match '^(el|rope)' \
  --exclude 'layout_fused'
```

Patterns use Python `re.search` semantics and may be repeated.

## Run hardware cases

Each `--case` has the form `REGEX::ARGS`. The runner expands the regex against
the discovered test IDs and applies the argument string to every match.

```bash
python -m tools.regression_runner run \
  --case '^(eladd|elmul)$::-n 1024' \
  --case '^eladd$::-n 4096' \
  --case '^rope$::-batch 1 -seq 8 -heads 32 -headdim 128' \
  --exclude 'layout_fused' \
  --backend hw \
  --fpga-alias C1
```

Use an empty suffix for tests with no arguments:

```bash
python -m tools.regression_runner run \
  --case '^basic$::' \
  --backend hw \
  --fpga-alias C1
```

The default configured build directory is `build`. The hardware backend
validates the selected FPGA alias and invokes the configured
`ci/run_black.sh` wrapper. Outside an existing Slurm allocation, the runner
acquires one FPGA allocation for the complete case list. Use `--no-srun` only
inside an existing allocation or when direct hardware access is intended.

The default per-case timeout is 30 minutes. It can be changed with values such
as `--timeout 90s`, `--timeout 20m`, or `--timeout 1h`.

Use `--dry-run` to validate selection and print commands without executing
tests.

## Results

Each run writes to:

```text
build/regression_runner_runs/<UTC timestamp>/
```

The directory contains:

- `manifest.json`: expanded cases and run configuration
- `results.csv`: spreadsheet-friendly incremental results
- `results.json`: structured incremental results
- `logs/<case-id>.log`: complete output for each case

Cases run sequentially. A failed or timed-out case does not stop later cases.
The process exits with `0` when all cases pass, `1` when any case fails or
times out, and `2` for runner validation or infrastructure errors.
