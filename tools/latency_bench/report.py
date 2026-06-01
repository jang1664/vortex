from __future__ import annotations

import csv
import hashlib
import json
from pathlib import Path
from typing import Any

import pandas as pd

from .suite import BenchSuite, suite_to_rows


RESULT_COLUMNS = [
    "suite", "case_id", "exec_key", "app", "kind", "op", "backend",
    "variant", "stage", "name", "args", "shape_json", "calls_per_forward",
    "fpga_bin_dir", "xclbin_sha256", "warmup", "iterations", "source",
    "status", "returncode", "raw_csv", "log_file", "samples", "min_us",
    "avg_us", "max_us", "p50_us", "p95_us",
]

TIMEOUT_RETURNCODES = {124, 137}


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
        return {}
    rows = []
    with path.open(newline="") as fp:
        for row in csv.reader(fp):
            if not row or row[0].startswith("#"):
                continue
            rows.append(row)
    if not rows:
        return {}
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


def classify_status(returncode: int, *, has_status: bool, bench: dict[str, Any]) -> str:
    if not has_status:
        return "not_run"
    if returncode in TIMEOUT_RETURNCODES:
        return "timeout"
    if "parse_error" in bench:
        return "parse_error"
    if returncode == 0 and bench:
        return "pass"
    return "fail"


def build_results(suite: BenchSuite, out_dir: Path, fpga_bin_dir: Path) -> pd.DataFrame:
    status_rows = read_status_csv(out_dir / "run_status.csv")
    xclbin = fpga_bin_dir / "vortex_afu.xclbin"
    xclbin_sha = sha256_file(xclbin) if xclbin.exists() else ""
    rows = []

    for row in suite_to_rows(suite):
        exec_key = row["exec_key"]
        status = status_rows.get(exec_key, {})
        raw_csv = Path(status.get("raw_csv", out_dir / "raw" / f"{exec_key}.csv"))
        log_file = Path(status.get("log_file", out_dir / "logs" / f"{exec_key}.log"))
        bench = read_bench_csv(raw_csv)
        returncode = int(status.get("returncode", 999)) if status else 999
        run_status = classify_status(returncode, has_status=bool(status), bench=bench)

        out = {
            **row,
            "fpga_bin_dir": str(fpga_bin_dir),
            "xclbin_sha256": xclbin_sha,
            "status": run_status,
            "returncode": returncode,
            "raw_csv": str(raw_csv),
            "log_file": str(log_file),
            "samples": bench.get("samples"),
            "min_us": bench.get("min_us"),
            "avg_us": bench.get("avg_us"),
            "max_us": bench.get("max_us"),
            "p50_us": bench.get("p50_us"),
            "p95_us": bench.get("p95_us"),
        }
        rows.append(out)

    return pd.DataFrame(rows, columns=RESULT_COLUMNS)


def build_summary(results: pd.DataFrame) -> pd.DataFrame:
    ok = results[results["status"] == "pass"].copy()
    if ok.empty:
        return pd.DataFrame(columns=[
            "suite", "stage", "group", "calls_per_forward", "weighted_total_avg_us",
            "weighted_total_p50_us", "weighted_total_p95_us", "case_count",
        ])
    for col in ("calls_per_forward", "avg_us", "p50_us", "p95_us"):
        ok[col] = pd.to_numeric(ok[col], errors="coerce").fillna(0.0)

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
            row.update({
                "calls_per_forward": total_calls,
                "weighted_total_avg_us": (sub["avg_us"] * sub["calls_per_forward"]).sum(),
                "weighted_total_p50_us": (sub["p50_us"] * sub["calls_per_forward"]).sum(),
                "weighted_total_p95_us": (sub["p95_us"] * sub["calls_per_forward"]).sum(),
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
