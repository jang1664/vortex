from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROGRESS_COLUMNS = [
    "timestamp_utc",
    "idx",
    "total",
    "run_id",
    "suite",
    "exec_key",
    "app",
    "args",
    "warmup",
    "iterations",
    "status",
    "returncode",
    "elapsed_wall_s",
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

TIMEOUT_RETURNCODES = {124, 137}


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
        return {"parse_error": f"expected_7_columns_got_{len(row)}"}

    return {
        "bench_label": row[0],
        "samples": row[1],
        "min_us": row[2],
        "avg_us": row[3],
        "max_us": row[4],
        "p50_us": row[5],
        "p95_us": row[6],
    }


def _classify_status(returncode: int, bench: dict[str, Any]) -> str:
    if returncode in TIMEOUT_RETURNCODES:
        return "timeout"
    if returncode == 0 and bench and "parse_error" not in bench:
        return "pass"
    if returncode == 0 and "parse_error" in bench:
        return "parse_error"
    return "fail"


def write_progress_header(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=PROGRESS_COLUMNS)
        writer.writeheader()


def _validate_or_write_header(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.stat().st_size == 0:
        write_progress_header(output)
        return

    with output.open(newline="") as fp:
        reader = csv.reader(fp)
        header = next(reader, [])
    if header != PROGRESS_COLUMNS:
        raise ValueError(f"progress CSV has unexpected header: {output}")


def append_progress_execution(
    *,
    output: Path,
    idx: int,
    total: int,
    run_id: str,
    suite: str,
    exec_key: str,
    app: str,
    args: str,
    warmup: int,
    iterations: int,
    returncode: int,
    elapsed_wall_s: str,
    raw_csv: Path,
    log_file: Path,
) -> None:
    bench = _read_bench_csv(raw_csv)
    row = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "idx": idx,
        "total": total,
        "run_id": run_id,
        "suite": suite,
        "exec_key": exec_key,
        "app": app,
        "args": args,
        "warmup": warmup,
        "iterations": iterations,
        "status": _classify_status(returncode, bench),
        "returncode": returncode,
        "elapsed_wall_s": elapsed_wall_s,
        "raw_csv": str(raw_csv),
        "log_file": str(log_file),
        "bench_label": bench.get("bench_label", ""),
        "samples": bench.get("samples", ""),
        "min_us": bench.get("min_us", ""),
        "avg_us": bench.get("avg_us", ""),
        "max_us": bench.get("max_us", ""),
        "p50_us": bench.get("p50_us", ""),
        "p95_us": bench.get("p95_us", ""),
        "parse_error": bench.get("parse_error", ""),
    }

    _validate_or_write_header(output)
    with output.open("a", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=PROGRESS_COLUMNS)
        writer.writerow(row)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Append one latency bench execution to progress.csv.")
    parser.add_argument("--output", required=True, type=Path, help="Run-local progress CSV.")
    parser.add_argument("--idx", required=True, type=int, help="One-based execution index.")
    parser.add_argument("--total", required=True, type=int, help="Total execution count.")
    parser.add_argument("--run-id", required=True, help="Run identifier shared by one latency_bench invocation.")
    parser.add_argument("--suite", required=True, help="Suite name.")
    parser.add_argument("--exec-key", required=True, help="Execution key.")
    parser.add_argument("--app", required=True, help="Benchmark app name.")
    parser.add_argument("--args", required=True, help="Benchmark app arguments.")
    parser.add_argument("--warmup", required=True, type=int, help="Warmup count.")
    parser.add_argument("--iterations", required=True, type=int, help="Iteration count.")
    parser.add_argument("--returncode", required=True, type=int, help="Benchmark process return code.")
    parser.add_argument("--elapsed-wall-s", required=True, help="Wall-clock seconds for the blackbox invocation.")
    parser.add_argument("--raw-csv", required=True, type=Path, help="Raw per-execution benchmark CSV.")
    parser.add_argument("--log-file", required=True, type=Path, help="Per-execution log file.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    append_progress_execution(
        output=args.output,
        idx=args.idx,
        total=args.total,
        run_id=args.run_id,
        suite=args.suite,
        exec_key=args.exec_key,
        app=args.app,
        args=args.args,
        warmup=args.warmup,
        iterations=args.iterations,
        returncode=args.returncode,
        elapsed_wall_s=args.elapsed_wall_s,
        raw_csv=args.raw_csv,
        log_file=args.log_file,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
