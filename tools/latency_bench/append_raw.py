from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


APPENDED_RAW_COLUMNS = [
    "timestamp_utc",
    "run_id",
    "suite",
    "exec_key",
    "app",
    "returncode",
    "failure_phase",
    "raw_csv",
    "log_file",
    "bench_label",
    "samples",
    "min_us",
    "avg_us",
    "max_us",
    "p50_us",
    "p95_us",
    "parse_error",
]


def _base_row(
    *,
    suite: str,
    run_id: str,
    exec_key: str,
    app: str,
    returncode: int,
    failure_phase: str,
    raw_csv: Path,
    log_file: Path,
) -> dict[str, Any]:
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "run_id": run_id,
        "suite": suite,
        "exec_key": exec_key,
        "app": app,
        "returncode": returncode,
        "failure_phase": failure_phase,
        "raw_csv": str(raw_csv),
        "log_file": str(log_file),
        "bench_label": "",
        "samples": "",
        "min_us": "",
        "avg_us": "",
        "max_us": "",
        "p50_us": "",
        "p95_us": "",
        "parse_error": "",
    }


def _parse_raw_rows(raw_csv: Path, base: dict[str, Any]) -> list[dict[str, Any]]:
    if not raw_csv.exists():
        return [{**base, "parse_error": "missing_raw_csv"}]

    rows: list[dict[str, Any]] = []
    with raw_csv.open(newline="") as fp:
        for row in csv.reader(fp):
            if not row or row[0].startswith("#"):
                continue
            out = dict(base)
            if len(row) < 7:
                out["parse_error"] = f"expected_7_columns_got_{len(row)}"
            else:
                out.update({
                    "bench_label": row[0],
                    "samples": row[1],
                    "min_us": row[2],
                    "avg_us": row[3],
                    "max_us": row[4],
                    "p50_us": row[5],
                    "p95_us": row[6],
                })
            rows.append(out)

    if not rows:
        return [{**base, "parse_error": "empty_raw_csv"}]
    return rows


def _validate_or_write_header(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.stat().st_size == 0:
        with output.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=APPENDED_RAW_COLUMNS)
            writer.writeheader()
        return

    with output.open(newline="") as fp:
        reader = csv.reader(fp)
        header = next(reader, [])
    if header != APPENDED_RAW_COLUMNS:
        raise ValueError(f"append raw CSV has unexpected header: {output}")


def append_raw_execution(
    *,
    output: Path,
    suite: str,
    run_id: str,
    exec_key: str,
    app: str,
    returncode: int,
    failure_phase: str = "",
    raw_csv: Path,
    log_file: Path,
) -> None:
    base = _base_row(
        suite=suite,
        run_id=run_id,
        exec_key=exec_key,
        app=app,
        returncode=returncode,
        failure_phase=failure_phase,
        raw_csv=raw_csv,
        log_file=log_file,
    )
    rows = _parse_raw_rows(raw_csv, base)
    _validate_or_write_header(output)
    with output.open("a", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=APPENDED_RAW_COLUMNS)
        writer.writerows(rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Append one benchmark raw CSV to an aggregate raw CSV.")
    parser.add_argument("--output", required=True, type=Path, help="Aggregate CSV to append to.")
    parser.add_argument("--suite", required=True, help="Suite name.")
    parser.add_argument("--run-id", required=True, help="Run identifier shared by one latency_bench invocation.")
    parser.add_argument("--exec-key", required=True, help="Execution key.")
    parser.add_argument("--app", required=True, help="Benchmark app name.")
    parser.add_argument("--returncode", required=True, type=int, help="Benchmark process return code.")
    parser.add_argument("--failure-phase", default="", choices=["", "build", "run"], help="Failed phase, if known.")
    parser.add_argument("--raw-csv", required=True, type=Path, help="Raw per-execution benchmark CSV.")
    parser.add_argument("--log-file", required=True, type=Path, help="Per-execution log file.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    append_raw_execution(
        output=args.output,
        suite=args.suite,
        run_id=args.run_id,
        exec_key=args.exec_key,
        app=args.app,
        returncode=args.returncode,
        failure_phase=args.failure_phase,
        raw_csv=args.raw_csv,
        log_file=args.log_file,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
