from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .power_summary import read_power_summary
from .perf_log import FPGA_CYCLE_COLUMNS, parse_fpga_cycle_stats
from .status import DEFAULT_POWER_MIN_SAMPLES, classify_status, power_sample_failure_reason


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
    "failure_phase",
    "failure_reason",
    "elapsed_wall_s",
    "raw_csv",
    "power_csv",
    "power_summary",
    "log_file",
    "bench_label",
    "samples",
    "min_us",
    "avg_us",
    "max_us",
    "p50_us",
    "p95_us",
    *FPGA_CYCLE_COLUMNS,
    "parse_error",
    "power_samples",
    "power_elapsed_s",
    "power_min_w",
    "power_avg_w",
    "power_max_w",
    "power_latency",
    "power_fpga_cycle",
    "power_parse_error",
]


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
    power_csv: Path | None = None,
    power_summary: Path | None = None,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
    failure_phase: str = "",
    failure_reason: str = "",
) -> None:
    bench = _read_bench_csv(raw_csv)
    cycle = parse_fpga_cycle_stats(log_file)
    power = read_power_summary(power_summary)
    measure_power = power_summary is not None
    if not failure_reason:
        if failure_phase == "build":
            failure_reason = "build"
        elif returncode in {124, 137}:
            failure_reason = "timeout"
        elif returncode == 0 and "parse_error" in bench:
            failure_reason = "parse_error"
        elif returncode == 0:
            failure_reason = power_sample_failure_reason(
                power,
                measure_power=measure_power,
                power_min_samples=power_min_samples,
            )
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
        "status": classify_status(
            returncode,
            bench=bench,
            power=power,
            measure_power=measure_power,
            power_min_samples=power_min_samples,
            failure_phase=failure_phase,
            failure_reason=failure_reason,
        ),
        "returncode": returncode,
        "failure_phase": failure_phase,
        "failure_reason": failure_reason,
        "elapsed_wall_s": elapsed_wall_s,
        "raw_csv": str(raw_csv),
        "power_csv": str(power_csv) if power_csv else "",
        "power_summary": str(power_summary) if power_summary else "",
        "log_file": str(log_file),
        "bench_label": bench.get("bench_label", ""),
        "samples": bench.get("samples", ""),
        "min_us": bench.get("min_us", ""),
        "avg_us": bench.get("avg_us", ""),
        "max_us": bench.get("max_us", ""),
        "p50_us": bench.get("p50_us", ""),
        "p95_us": bench.get("p95_us", ""),
        **cycle,
        "parse_error": bench.get("parse_error", ""),
        "power_samples": power.get("power_samples", ""),
        "power_elapsed_s": power.get("power_elapsed_s", ""),
        "power_min_w": power.get("power_min_w", ""),
        "power_avg_w": power.get("power_avg_w", ""),
        "power_max_w": power.get("power_max_w", ""),
        "power_latency": power.get("power_latency", ""),
        "power_fpga_cycle": power.get("power_fpga_cycle", ""),
        "power_parse_error": power.get("power_parse_error", ""),
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
    parser.add_argument("--failure-phase", default="", choices=["", "build", "run"], help="Failed phase, if known.")
    parser.add_argument(
        "--failure-reason",
        default="",
        choices=["", "build", "timeout", "xrt_context_open", "run", "parse_error", "power_samples_low"],
        help="Specific failure reason, if known.",
    )
    parser.add_argument("--elapsed-wall-s", required=True, help="Wall-clock seconds for the blackbox invocation.")
    parser.add_argument("--raw-csv", required=True, type=Path, help="Raw per-execution benchmark CSV.")
    parser.add_argument("--power-csv", default=None, type=Path, help="Raw per-execution power CSV, when enabled.")
    parser.add_argument("--power-summary", default=None, type=Path, help="Per-execution power summary CSV, when enabled.")
    parser.add_argument(
        "--power-min-samples",
        default=DEFAULT_POWER_MIN_SAMPLES,
        type=int,
        help="Minimum required power samples when power measurement is enabled; 0 disables this status check.",
    )
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
        failure_phase=args.failure_phase,
        failure_reason=args.failure_reason,
        elapsed_wall_s=args.elapsed_wall_s,
        raw_csv=args.raw_csv,
        power_csv=args.power_csv,
        power_summary=args.power_summary,
        power_min_samples=args.power_min_samples,
        log_file=args.log_file,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
