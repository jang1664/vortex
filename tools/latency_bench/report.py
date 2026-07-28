from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
from typing import Any

import pandas as pd

from .power_summary import read_power_summary
from .perf_log import FPGA_CYCLE_COLUMNS, parse_fpga_cycle_stats
from .status import DEFAULT_POWER_MIN_SAMPLES, classify_status, power_sample_failure_reason
from .suite import BenchSuite, suite_to_rows


RESULT_COLUMNS = [
    "suite", "case_id", "exec_key", "app", "kind", "op", "backend",
    "variant", "stage", "name", "args", "measurement_args",
    "latency_shape_json", "padded_args", "shape_json",
    "calls_per_forward", "decode_step_count", "out_tokens",
    "decode_sample_weight",
    "fpga_bin_dir", "xclbin_sha256", "warmup", "iterations", "source",
    "status", "returncode", "failure_phase", "failure_reason", "raw_csv",
    "power_csv", "power_summary", "measure_latency", "measure_power",
    "power_samples", "power_elapsed_s", "power_min_w", "power_avg_w",
    "power_max_w", "power_std_w", "power_total_min_w", "power_total_avg_w",
    "power_total_max_w", "power_idle_w", "power_idle_std_w", "power_idle_vcc_avg_w",
    "power_idle_pcie_avg_w", "power_vcc_min_w", "power_vcc_avg_w",
    "power_vcc_max_w", "power_pcie_min_w", "power_pcie_avg_w",
    "power_pcie_max_w", "power_dynamic_avg_w", "power_dynamic_peak_w",
    "power_dynamic_stderr_w", "power_dynamic_energy_j", "power_latency", "power_fpga_cycle",
    "power_kernel_iterations", "power_kernel_iterations_auto", "power_target_sec",
    "power_source", "power_raw_truncated",
    "power_parse_error",
    "log_file", "elapsed_wall_s",
    "samples", "min_us", "avg_us", "max_us", "p50_us", "p95_us",
    *FPGA_CYCLE_COLUMNS,
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_status_csv(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    with path.open(newline="") as fp:
        return {row["exec_key"]: row for row in csv.DictReader(fp)}


def read_bench_csv(path: Path) -> dict[str, Any]:
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


def _parse_bool_cell(value: Any) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def build_results(
    suite: BenchSuite,
    out_dir: Path,
    fpga_bin_dir: Path,
    *,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
) -> pd.DataFrame:
    status_rows = read_status_csv(out_dir / "run_status.csv")
    xclbin = fpga_bin_dir / "vortex_afu.xclbin"
    xclbin_sha = sha256_file(xclbin) if xclbin.exists() else ""
    rows = []

    for row in suite_to_rows(suite):
        exec_key = row["exec_key"]
        status = status_rows.get(exec_key, {})
        raw_csv = Path(status.get("raw_csv", out_dir / "raw" / f"{exec_key}.csv"))
        log_file = Path(status.get("log_file", out_dir / "logs" / f"{exec_key}.log"))
        power_summary = status.get("power_summary", "")
        measure_power = _parse_bool_cell(status.get("measure_power", ""))
        bench = read_bench_csv(raw_csv)
        cycle = parse_fpga_cycle_stats(log_file)
        power = read_power_summary(power_summary if measure_power else None)
        returncode = int(status.get("returncode", 999)) if status else 999
        failure_phase = status.get("failure_phase", "")
        failure_reason = status.get("failure_reason", "")
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
        run_status = classify_status(
            returncode,
            has_status=bool(status),
            bench=bench,
            power=power,
            measure_power=measure_power,
            power_min_samples=power_min_samples,
            failure_phase=failure_phase,
            failure_reason=failure_reason,
        )

        out = {
            **row,
            "fpga_bin_dir": str(fpga_bin_dir),
            "xclbin_sha256": xclbin_sha,
            "status": run_status,
            "returncode": returncode,
            "failure_phase": failure_phase,
            "failure_reason": failure_reason,
            "raw_csv": str(raw_csv),
            "power_csv": status.get("power_csv", ""),
            "power_summary": power_summary,
            "measure_latency": status.get("measure_latency", ""),
            "measure_power": status.get("measure_power", ""),
            "power_samples": power.get("power_samples"),
            "power_elapsed_s": power.get("power_elapsed_s"),
            "power_min_w": power.get("power_min_w"),
            "power_avg_w": power.get("power_avg_w"),
            "power_max_w": power.get("power_max_w"),
            "power_std_w": power.get("power_std_w"),
            "power_total_min_w": power.get("power_total_min_w"),
            "power_total_avg_w": power.get("power_total_avg_w"),
            "power_total_max_w": power.get("power_total_max_w"),
            "power_idle_w": power.get("power_idle_w"),
            "power_idle_std_w": power.get("power_idle_std_w"),
            "power_idle_vcc_avg_w": power.get("power_idle_vcc_avg_w"),
            "power_idle_pcie_avg_w": power.get("power_idle_pcie_avg_w"),
            "power_vcc_min_w": power.get("power_vcc_min_w"),
            "power_vcc_avg_w": power.get("power_vcc_avg_w"),
            "power_vcc_max_w": power.get("power_vcc_max_w"),
            "power_pcie_min_w": power.get("power_pcie_min_w"),
            "power_pcie_avg_w": power.get("power_pcie_avg_w"),
            "power_pcie_max_w": power.get("power_pcie_max_w"),
            "power_dynamic_avg_w": power.get("power_dynamic_avg_w"),
            "power_dynamic_peak_w": power.get("power_dynamic_peak_w"),
            "power_dynamic_stderr_w": power.get("power_dynamic_stderr_w"),
            "power_dynamic_energy_j": power.get("power_dynamic_energy_j"),
            "power_latency": power.get("power_latency"),
            "power_fpga_cycle": power.get("power_fpga_cycle"),
            "power_kernel_iterations": power.get("power_kernel_iterations"),
            "power_kernel_iterations_auto": power.get("power_kernel_iterations_auto"),
            "power_target_sec": power.get("power_target_sec"),
            "power_source": power.get("power_source"),
            "power_raw_truncated": power.get("power_raw_truncated"),
            "power_parse_error": power.get("power_parse_error", ""),
            "log_file": str(log_file),
            "elapsed_wall_s": status.get("elapsed_wall_s"),
            "samples": bench.get("samples"),
            "min_us": bench.get("min_us"),
            "avg_us": bench.get("avg_us"),
            "max_us": bench.get("max_us"),
            "p50_us": bench.get("p50_us"),
            "p95_us": bench.get("p95_us"),
            **cycle,
        }
        rows.append(out)

    return pd.DataFrame(rows, columns=RESULT_COLUMNS)


def build_summary(results: pd.DataFrame) -> pd.DataFrame:
    ok = results[results["status"] == "pass"].copy()
    if ok.empty:
        return pd.DataFrame(columns=[
            "suite", "stage", "group", "calls_per_forward", "effective_calls",
            "out_tokens", "avg_per_output_token_us", "weighted_total_avg_us",
            "weighted_total_p50_us", "weighted_total_p95_us", "case_count",
        ])
    for col in (
        "calls_per_forward", "decode_step_count", "out_tokens",
        "decode_sample_weight",
        "avg_us", "p50_us", "p95_us",
    ):
        ok[col] = pd.to_numeric(ok[col], errors="coerce").fillna(0.0)
    ok["effective_calls"] = (
        ok["calls_per_forward"]
        * ok["decode_step_count"]
        * ok["decode_sample_weight"]
    )

    rows = []
    group_specs = [
        ("stage", ["suite", "stage"]),
        ("kind", ["suite", "stage", "kind"]),
        ("backend", ["suite", "stage", "backend"]),
        ("op", ["suite", "stage", "op"]),
        ("kernel", ["suite", "stage", "name"]),
        ("total", ["suite"]),
    ]
    for group_name, cols in group_specs:
        for keys, sub in ok.groupby(cols, dropna=False, sort=True):
            if not isinstance(keys, tuple):
                keys = (keys,)
            if group_name in ("kind", "backend", "op", "kernel") and not str(keys[2]):
                continue
            row = {"suite": keys[0], "stage": "", "group": group_name}
            if group_name == "stage":
                row["stage"] = keys[1]
                row["group"] = "stage_total"
            elif group_name == "kind":
                row["stage"] = keys[1]
                row["group"] = f"kind:{keys[2]}"
            elif group_name == "backend":
                row["stage"] = keys[1]
                row["group"] = f"backend:{keys[2]}"
            elif group_name == "op":
                row["stage"] = keys[1]
                row["group"] = f"op:{keys[2]}"
            elif group_name == "kernel":
                row["stage"] = keys[1]
                row["group"] = f"kernel:{keys[2]}"
            total_calls = sub["calls_per_forward"].sum()
            effective_calls = sub["effective_calls"].sum()
            weighted_avg = (sub["avg_us"] * sub["effective_calls"]).sum()
            only_generation = set(sub["stage"].astype(str)) == {"generation"}
            output_counts = (
                {int(value) for value in sub["out_tokens"] if value > 0}
                if only_generation else set()
            )
            output_tokens = next(iter(output_counts)) if len(output_counts) == 1 else 0
            row.update({
                "calls_per_forward": total_calls,
                "effective_calls": effective_calls,
                "out_tokens": output_tokens,
                "avg_per_output_token_us": (
                    weighted_avg / output_tokens if output_tokens > 0 else float("nan")
                ),
                "weighted_total_avg_us": weighted_avg,
                "weighted_total_p50_us": (sub["p50_us"] * sub["effective_calls"]).sum(),
                "weighted_total_p95_us": (sub["p95_us"] * sub["effective_calls"]).sum(),
                "case_count": len(sub),
            })
            rows.append(row)
    return pd.DataFrame(rows)


def write_manifest(suite: BenchSuite, out_dir: Path, extra: dict[str, Any]) -> None:
    manifest = {
        "suite": suite.name,
        "source_path": str(suite.source_path) if suite.source_path else "",
        "defaults": suite.defaults.__dict__,
        "case_count": len(suite.cases),
        **extra,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
