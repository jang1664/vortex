from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .power_summary import read_power_summary
from .perf_log import FPGA_CYCLE_COLUMNS, parse_fpga_cycle_stats
from .status import DEFAULT_POWER_MIN_SAMPLES, classify_status, power_sample_failure_reason


RAW_DB_COLUMNS = [
    "run_id",
    "timestamp_utc",
    "fpga_bin_label",
    "git_commit",
    "git_branch",
    "git_dirty",
    "suite",
    "case_id",
    "exec_key",
    "app",
    "kind",
    "op",
    "backend",
    "variant",
    "stage",
    "name",
    "args",
    "shape_json",
    "calls_per_forward",
    "fpga_bin_dir",
    "xclbin_sha256",
    "warmup",
    "iterations",
    "source",
    "status",
    "returncode",
    "failure_phase",
    "failure_reason",
    "raw_csv",
    "power_csv",
    "power_summary",
    "measure_latency",
    "measure_power",
    "power_samples",
    "power_elapsed_s",
    "power_min_w",
    "power_avg_w",
    "power_max_w",
    "power_parse_error",
    "log_file",
    "elapsed_wall_s",
    "samples",
    "min_us",
    "avg_us",
    "max_us",
    "p50_us",
    "p95_us",
    *FPGA_CYCLE_COLUMNS,
]


def _normalize_args(value: str) -> str:
    return " ".join(str(value).split())


def _parse_int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _clean_raw_value(value: object) -> str:
    if value is None:
        return ""
    try:
        if value != value:
            return ""
    except TypeError:
        pass
    return str(value)


def _parse_bool_cell(value: object, *, default: bool) -> bool:
    text = _clean_raw_value(value).strip().lower()
    if text in ("1", "true", "yes", "on"):
        return True
    if text in ("0", "false", "no", "off"):
        return False
    return default


def _bool_csv(value: bool) -> str:
    return "1" if value else "0"


def _measurement_key(
    *,
    fpga_bin_label: object,
    xclbin_sha256: object,
    exec_key: object,
    app: object,
    args: object,
    warmup: object,
    iterations: object,
) -> tuple[str, str, str, str, str, int | None, int | None]:
    return (
        _clean_raw_value(fpga_bin_label),
        _clean_raw_value(xclbin_sha256),
        _clean_raw_value(exec_key),
        _clean_raw_value(app),
        _normalize_args(_clean_raw_value(args)),
        _parse_int(warmup),
        _parse_int(iterations),
    )


def _measurement_key_from_row(row: dict[str, object]) -> tuple[str, str, str, str, str, int | None, int | None]:
    return _measurement_key(
        fpga_bin_label=row.get("fpga_bin_label", ""),
        xclbin_sha256=row.get("xclbin_sha256", ""),
        exec_key=row.get("exec_key", ""),
        app=row.get("app", ""),
        args=row.get("args", ""),
        warmup=row.get("warmup", ""),
        iterations=row.get("iterations", ""),
    )


def _ensure_raw_db_schema(raw_db: Path) -> None:
    if not raw_db.exists() or raw_db.stat().st_size == 0:
        return

    with raw_db.open(newline="") as fp:
        reader = csv.reader(fp)
        header = next(reader, [])
    if header == RAW_DB_COLUMNS:
        return

    with raw_db.open(newline="") as fp:
        existing_rows = list(csv.DictReader(fp))

    tmp = raw_db.with_suffix(raw_db.suffix + ".tmp")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        for row in existing_rows:
            writer.writerow({column: _clean_raw_value(row.get(column, "")) for column in RAW_DB_COLUMNS})
    tmp.replace(raw_db)


def _raw_db_rows(results: Any, *, run_id: str, fpga_bin_label: str) -> Any:
    rows = results.copy()
    rows.insert(0, "timestamp_utc", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    rows.insert(0, "run_id", run_id)
    rows.insert(2, "fpga_bin_label", fpga_bin_label)
    return rows.reindex(columns=RAW_DB_COLUMNS)


def _write_raw_rows(
    rows: list[dict[str, object]],
    raw_db: Path,
    *,
    mode: str,
    run_id: str,
) -> int:
    if not rows:
        return 0

    raw_db.parent.mkdir(parents=True, exist_ok=True)
    _ensure_raw_db_schema(raw_db)

    if mode == "append":
        write_header = not raw_db.exists() or raw_db.stat().st_size == 0
        with raw_db.open("a", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
            if write_header:
                writer.writeheader()
            for row in rows:
                writer.writerow({column: _clean_raw_value(row.get(column, "")) for column in RAW_DB_COLUMNS})
        return 0

    replacement_keys = {_measurement_key_from_row(row) for row in rows}
    existing_rows: list[dict[str, str]] = []
    if raw_db.exists() and raw_db.stat().st_size > 0:
        with raw_db.open(newline="") as fp:
            existing_rows = list(csv.DictReader(fp))

    replaced_count = 0
    kept_rows: list[dict[str, object]] = []
    for row in existing_rows:
        replace_row = _measurement_key_from_row(row) in replacement_keys
        if mode == "replace-run":
            replace_row = replace_row and row.get("run_id") == run_id
        if replace_row:
            replaced_count += 1
        else:
            kept_rows.append(row)

    output_rows = kept_rows + rows
    tmp = raw_db.with_suffix(raw_db.suffix + ".tmp")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        for row in output_rows:
            writer.writerow({column: _clean_raw_value(row.get(column, "")) for column in RAW_DB_COLUMNS})
    tmp.replace(raw_db)
    return replaced_count


def append_raw_db(results: Any, out_root: Path, *, run_id: str, fpga_bin_label: str) -> None:
    if results.empty:
        return
    rows = _raw_db_rows(results, run_id=run_id, fpga_bin_label=fpga_bin_label)
    _write_raw_rows(rows.to_dict("records"), out_root / "raw_db.csv", mode="append", run_id=run_id)


def replace_raw_db_rows(results: Any, out_root: Path, *, run_id: str, fpga_bin_label: str) -> int:
    if results.empty:
        return 0
    rows = _raw_db_rows(results, run_id=run_id, fpga_bin_label=fpga_bin_label)
    return _write_raw_rows(rows.to_dict("records"), out_root / "raw_db.csv", mode="replace", run_id=run_id)


def _case_rows_for_exec(cases_csv: Path, exec_key: str) -> list[dict[str, str]]:
    with cases_csv.open(newline="") as fp:
        return [row for row in csv.DictReader(fp) if row.get("exec_key") == exec_key]


def _read_bench_csv(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"parse_error": "missing_raw_csv"}
    rows = []
    with path.open(newline="") as fp:
        for row in csv.reader(fp):
            if not row or row[0].startswith("#"):
                continue
            rows.append(row)
    if not rows:
        return {"parse_error": "empty_raw_csv"}
    row = rows[-1]
    if len(row) < 7:
        return {"parse_error": f"expected 7 columns, got {len(row)}"}
    try:
        return {
            "bench_label": row[0],
            "samples": int(float(row[1])),
            "min_us": float(row[2]),
            "avg_us": float(row[3]),
            "max_us": float(row[4]),
            "p50_us": float(row[5]),
            "p95_us": float(row[6]),
        }
    except ValueError as exc:
        return {"parse_error": str(exc)}


def _default_failure_reason(
    *,
    returncode: int,
    failure_phase: str,
    failure_reason: str,
    bench: dict[str, Any],
    power: dict[str, Any],
    measure_power: bool,
    power_min_samples: int,
) -> str:
    if failure_reason:
        return failure_reason
    if failure_phase == "build":
        return "build"
    if returncode in {124, 137}:
        return "timeout"
    if returncode == 0 and "parse_error" in bench:
        return "parse_error"
    if returncode == 0:
        return power_sample_failure_reason(
            power,
            measure_power=measure_power,
            power_min_samples=power_min_samples,
        )
    return ""


def append_raw_execution(
    *,
    output: Path,
    cases_csv: Path,
    exec_key: str,
    run_id: str,
    fpga_bin_label: str,
    fpga_bin_dir: Path,
    xclbin_sha256: str,
    git_commit: str,
    git_branch: str,
    git_dirty: str,
    returncode: int,
    failure_phase: str,
    failure_reason: str,
    raw_csv: Path,
    power_csv: Path | None,
    power_summary: Path | None,
    measure_latency: bool,
    measure_power: bool,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
    log_file: Path,
    elapsed_wall_s: str,
    mode: str,
) -> int:
    cases = _case_rows_for_exec(cases_csv, exec_key)
    if not cases:
        raise ValueError(f"cases CSV has no rows for exec_key={exec_key!r}: {cases_csv}")

    bench = _read_bench_csv(raw_csv)
    cycle = parse_fpga_cycle_stats(log_file)
    power = read_power_summary(power_summary if measure_power else None)
    failure_reason = _default_failure_reason(
        returncode=returncode,
        failure_phase=failure_phase,
        failure_reason=failure_reason,
        bench=bench,
        power=power,
        measure_power=measure_power,
        power_min_samples=power_min_samples,
    )
    status = classify_status(
        returncode,
        bench=bench,
        power=power,
        measure_power=measure_power,
        power_min_samples=power_min_samples,
        failure_phase=failure_phase,
        failure_reason=failure_reason,
    )
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

    rows: list[dict[str, object]] = []
    for case in cases:
        row = {column: "" for column in RAW_DB_COLUMNS}
        row.update({column: case.get(column, "") for column in RAW_DB_COLUMNS})
        row.update({
            "run_id": run_id,
            "timestamp_utc": timestamp,
            "fpga_bin_label": fpga_bin_label,
            "git_commit": git_commit,
            "git_branch": git_branch,
            "git_dirty": git_dirty,
            "fpga_bin_dir": str(fpga_bin_dir),
            "xclbin_sha256": xclbin_sha256,
            "status": status,
            "returncode": returncode,
            "failure_phase": failure_phase,
            "failure_reason": failure_reason,
            "raw_csv": str(raw_csv),
            "power_csv": str(power_csv) if measure_power and power_csv else "",
            "power_summary": str(power_summary) if measure_power and power_summary else "",
            "measure_latency": _bool_csv(measure_latency),
            "measure_power": _bool_csv(measure_power),
            "power_samples": power.get("power_samples", ""),
            "power_elapsed_s": power.get("power_elapsed_s", ""),
            "power_min_w": power.get("power_min_w", ""),
            "power_avg_w": power.get("power_avg_w", ""),
            "power_max_w": power.get("power_max_w", ""),
            "power_parse_error": power.get("power_parse_error", ""),
            "log_file": str(log_file),
            "elapsed_wall_s": elapsed_wall_s,
            "samples": bench.get("samples", ""),
            "min_us": bench.get("min_us", ""),
            "avg_us": bench.get("avg_us", ""),
            "max_us": bench.get("max_us", ""),
            "p50_us": bench.get("p50_us", ""),
            "p95_us": bench.get("p95_us", ""),
            **cycle,
        })
        rows.append(row)

    return _write_raw_rows(rows, output, mode=mode, run_id=run_id)


def _parse_bool_arg(value: str) -> bool:
    return _parse_bool_cell(value, default=False)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Append one latency bench execution to raw_db.csv.")
    parser.add_argument("--output", required=True, type=Path, help="Top-level raw_db.csv.")
    parser.add_argument("--cases-csv", required=True, type=Path, help="Run-local cases.csv.")
    parser.add_argument("--exec-key", required=True, help="Execution key.")
    parser.add_argument("--run-id", required=True, help="Run identifier shared by one latency_bench invocation.")
    parser.add_argument("--fpga-bin-label", required=True, help="FPGA binary label.")
    parser.add_argument("--fpga-bin-dir", required=True, type=Path, help="FPGA binary directory.")
    parser.add_argument("--xclbin-sha256", default="", help="SHA256 of vortex_afu.xclbin.")
    parser.add_argument("--git-commit", default="", help="Git commit hash.")
    parser.add_argument("--git-branch", default="", help="Git branch name.")
    parser.add_argument("--git-dirty", default="", help="Git dirty flag.")
    parser.add_argument("--returncode", required=True, type=int, help="Benchmark process return code.")
    parser.add_argument("--failure-phase", default="", choices=["", "build", "run"], help="Failed phase, if known.")
    parser.add_argument(
        "--failure-reason",
        default="",
        choices=["", "build", "timeout", "xrt_context_open", "run", "parse_error", "power_samples_low"],
        help="Specific failure reason, if known.",
    )
    parser.add_argument("--raw-csv", required=True, type=Path, help="Raw per-execution benchmark CSV.")
    parser.add_argument("--power-csv", default=None, type=Path, help="Raw per-execution power CSV, when enabled.")
    parser.add_argument("--power-summary", default=None, type=Path, help="Per-execution power summary CSV, when enabled.")
    parser.add_argument("--measure-latency", required=True, type=_parse_bool_arg, help="Whether latency was enabled.")
    parser.add_argument("--measure-power", required=True, type=_parse_bool_arg, help="Whether power was enabled.")
    parser.add_argument(
        "--power-min-samples",
        default=DEFAULT_POWER_MIN_SAMPLES,
        type=int,
        help="Minimum required power samples when power measurement is enabled; 0 disables this status check.",
    )
    parser.add_argument("--log-file", required=True, type=Path, help="Per-execution log file.")
    parser.add_argument("--elapsed-wall-s", required=True, help="Wall-clock seconds for the blackbox invocation.")
    parser.add_argument(
        "--mode",
        default="append",
        choices=["append", "replace", "replace-run"],
        help="How to handle existing rows with the same measurement key.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    append_raw_execution(
        output=args.output,
        cases_csv=args.cases_csv,
        exec_key=args.exec_key,
        run_id=args.run_id,
        fpga_bin_label=args.fpga_bin_label,
        fpga_bin_dir=args.fpga_bin_dir,
        xclbin_sha256=args.xclbin_sha256,
        git_commit=args.git_commit,
        git_branch=args.git_branch,
        git_dirty=args.git_dirty,
        returncode=args.returncode,
        failure_phase=args.failure_phase,
        failure_reason=args.failure_reason,
        raw_csv=args.raw_csv,
        power_csv=args.power_csv,
        power_summary=args.power_summary,
        measure_latency=args.measure_latency,
        measure_power=args.measure_power,
        power_min_samples=args.power_min_samples,
        log_file=args.log_file,
        elapsed_wall_s=args.elapsed_wall_s,
        mode=args.mode,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
