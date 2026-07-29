# Latency Bench `latest` Live Snapshot Gap

Date: 2026-07-29

## Summary

During a hardware run, the canonical `raw_db.csv` and the run-local progress files are updated after each completed execution, but some files under `<output>/<fpga_bin>/latest/` remain at their initial state until the run finishes or is interrupted through the handled `KeyboardInterrupt` path.

This does not corrupt measurements or break `--skip-existing`. It does make `latest/` an incomplete source for monitoring an active run.

## Observed behavior

For active Llama2 and Llama3 C1/C3 decode runs:

- `latest/cases.csv` matched the active run's `cases.csv`.
- `<output>/<fpga_bin>/raw_db.csv` was updated after every completed execution.
- The completed rows in `raw_db.csv` matched the run-local `progress.csv` exactly.
- `latest/progress.csv` and `latest/attempt_status.csv` still contained only their initial headers while the run-local files contained completed executions.
- `latest/run_state.json` reported `status: running`, but its `updated_at_utc` remained at the run-start time.

Pending rows in `raw_db.csv` have an empty `status` because execution rows are pre-seeded before the hardware run. This is expected. Only `status=pass` rows are eligible for `--skip-existing`, so an interrupted run safely retries unfinished rows.

## Cause

`run_suite()` publishes static run artifacts to `latest/` before launching the generated hardware script. The generated script updates its run-local `progress.csv` and `attempt_status.csv`, and updates the root `raw_db.csv`, but it does not republish those changing files to `latest/`.

`publish_run_latest()` copies progress artifacts only after the subprocess returns or when the parent handles `KeyboardInterrupt`. Consequently, normal in-progress monitoring through `latest/` is stale. Termination that bypasses the handled interrupt path can leave it stale permanently for that run.

## Impact

- Measurement results remain valid in the run directory and root `raw_db.csv`.
- `--skip-existing` remains correct because it reads the root `raw_db.csv`.
- `latest/cases.csv` remains useful because cases are static for an ordinary hardware run.
- Monitoring tools that read only `latest/progress.csv`, `latest/attempt_status.csv`, or `latest/run_state.json` under-report progress.
- A user inspecting `latest/` after an abrupt interruption may not see the last completed executions even though they are present in the run directory and `raw_db.csv`.

## Recommended behavior

Publish the small, changing status artifacts after every completed execution, or at a short throttled interval:

- `progress.csv`
- `attempt_status.csv`
- `run_status.csv`, when present
- `run_state.json` with a refreshed `updated_at_utc`

Continue using atomic replacement so readers never observe partially written CSV or JSON files. Do not recopy large static artifacts such as `cases.csv` or expanded suite YAML after every case.

The root `raw_db.csv` should remain the authoritative measurement database. `latest/` should be a convenient atomic snapshot of the newest run, not a second database.

## Acceptance criteria

1. During a multi-case hardware run, `latest/progress.csv` follows the run-local progress within one completed execution or the configured publish interval.
2. `latest/attempt_status.csv` exposes the same completed attempts as the run-local file.
3. `latest/run_state.json.updated_at_utc` advances while work is completing and retains the active run ID.
4. Interrupting a run leaves `latest/` at the last fully published state.
5. No reader can observe a partial CSV or JSON write.
6. Per-case publication does not copy `cases.csv`, suite YAML, raw power samples, or logs.
7. Existing `raw_db.csv` replacement, `--skip-existing`, retry, and final publication behavior remains unchanged.
