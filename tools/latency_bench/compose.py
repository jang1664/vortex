from __future__ import annotations

import math
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pandas as pd

from .suite import BenchSuite, suite_to_rows


METRIC_COLUMNS = ("avg_us", "p50_us", "p95_us", "min_us", "max_us")
SELECT_POLICIES = ("median", "latest", "mean", "min", "strict")
MISSING_POLICIES = ("error", "nan", "skip")


@dataclass(frozen=True)
class ComposeOptions:
    raw_dbs: tuple[Path, ...]
    out: Path
    metric: str = "p50_us"
    select: str = "median"
    missing: str = "error"
    fpga_bin_label: str | None = None
    xclbin_sha256: str | None = None


def normalize_args(args: str) -> str:
    try:
        return " ".join(shlex.split(str(args)))
    except ValueError:
        return " ".join(str(args).split())


def _read_raw_dbs(paths: tuple[Path, ...]) -> pd.DataFrame:
    if not paths:
        raise ValueError("at least one --raw-db is required")

    frames = []
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f"raw DB not found: {path}")
        frame = pd.read_csv(path)
        frame.insert(0, "raw_db", str(path))
        frames.append(frame)
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def _require_columns(raw: pd.DataFrame, columns: tuple[str, ...] | list[str]) -> None:
    missing = [column for column in columns if column not in raw.columns]
    if missing:
        raise ValueError(f"raw DB is missing required columns: {', '.join(missing)}")


def _unique_join(values: pd.Series) -> str:
    out = []
    seen = set()
    for value in values.dropna().astype(str):
        if not value or value in seen:
            continue
        seen.add(value)
        out.append(value)
    return ";".join(out)


def _numeric(series: pd.Series) -> pd.Series:
    return pd.to_numeric(series, errors="coerce")


def _select_value(matches: pd.DataFrame, metric: str, policy: str) -> tuple[float, pd.Series | None]:
    values = _numeric(matches[metric]).dropna()
    if values.empty:
        return math.nan, None

    if policy == "strict":
        if len(matches) != 1:
            raise ValueError(f"strict selection expected exactly one match, got {len(matches)}")
        row = matches.iloc[0]
        return float(pd.to_numeric(row[metric], errors="coerce")), row
    if policy == "latest":
        if "timestamp_utc" in matches.columns:
            ordered = matches.assign(_ts=pd.to_datetime(matches["timestamp_utc"], errors="coerce"))
            ordered = ordered.sort_values(["_ts"], kind="stable")
            row = ordered.iloc[-1]
        else:
            row = matches.iloc[-1]
        return float(pd.to_numeric(row[metric], errors="coerce")), row
    if policy == "mean":
        return float(values.mean()), None
    if policy == "min":
        idx = values.idxmin()
        row = matches.loc[idx]
        return float(values.loc[idx]), row
    if policy == "median":
        return float(values.median()), None
    raise ValueError(f"unknown select policy: {policy}")


def _compose_row(
    case: dict[str, Any],
    matches: pd.DataFrame,
    *,
    metric: str,
    select: str,
) -> dict[str, Any]:
    value, selected = _select_value(matches, metric, select)
    calls = float(case["calls_per_forward"])
    row = {
        **case,
        "metric": metric,
        "latency_us": value,
        "weighted_latency_us": value * calls if not math.isnan(value) else math.nan,
        "match_count": len(matches),
        "select_policy": select,
        "compose_status": "pass",
        "source_raw_dbs": _unique_join(matches["raw_db"]),
        "source_run_ids": _unique_join(matches["run_id"]) if "run_id" in matches.columns else "",
        "source_xclbin_sha256s": _unique_join(matches["xclbin_sha256"]) if "xclbin_sha256" in matches.columns else "",
    }
    if selected is not None:
        row["selected_run_id"] = str(selected.get("run_id", ""))
        row["selected_timestamp_utc"] = str(selected.get("timestamp_utc", ""))
    else:
        row["selected_run_id"] = ""
        row["selected_timestamp_utc"] = ""
    return row


def compose_latency(suite: BenchSuite, options: ComposeOptions) -> pd.DataFrame:
    if options.metric not in METRIC_COLUMNS:
        raise ValueError(f"metric must be one of {', '.join(METRIC_COLUMNS)}")
    if options.select not in SELECT_POLICIES:
        raise ValueError(f"select must be one of {', '.join(SELECT_POLICIES)}")
    if options.missing not in MISSING_POLICIES:
        raise ValueError(f"missing must be one of {', '.join(MISSING_POLICIES)}")

    raw = _read_raw_dbs(options.raw_dbs)
    _require_columns(raw, ["app", "args", "status", options.metric])
    raw = raw[raw["status"].astype(str) == "pass"].copy()
    raw["_normalized_args"] = raw["args"].astype(str).map(normalize_args)

    if options.fpga_bin_label:
        _require_columns(raw, ["fpga_bin_label"])
        raw = raw[raw["fpga_bin_label"].astype(str) == options.fpga_bin_label].copy()
    if options.xclbin_sha256:
        _require_columns(raw, ["xclbin_sha256"])
        raw = raw[raw["xclbin_sha256"].astype(str) == options.xclbin_sha256].copy()

    rows = []
    missing_cases = []
    for case in suite_to_rows(suite):
        normalized_args = normalize_args(str(case["args"]))
        matches = raw[
            (raw["app"].astype(str) == str(case["app"]))
            & (raw["_normalized_args"] == normalized_args)
        ].copy()
        if matches.empty:
            missing_cases.append(str(case["case_id"]))
            if options.missing == "skip":
                continue
            if options.missing == "nan":
                rows.append({
                    **case,
                    "metric": options.metric,
                    "latency_us": math.nan,
                    "weighted_latency_us": math.nan,
                    "match_count": 0,
                    "select_policy": options.select,
                    "compose_status": "missing",
                    "source_raw_dbs": "",
                    "source_run_ids": "",
                    "source_xclbin_sha256s": "",
                    "selected_run_id": "",
                    "selected_timestamp_utc": "",
                })
                continue
            continue
        try:
            rows.append(_compose_row(case, matches, metric=options.metric, select=options.select))
        except ValueError as exc:
            raise ValueError(f"{case['case_id']}: {exc}") from exc

    if missing_cases and options.missing == "error":
        preview = ", ".join(missing_cases[:10])
        suffix = "" if len(missing_cases) <= 10 else f", ... ({len(missing_cases)} total)"
        raise ValueError(f"raw DB is missing measurements for cases: {preview}{suffix}")

    return pd.DataFrame(rows)


def write_compose_outputs(composed: pd.DataFrame, out: Path) -> tuple[Path, Path | None]:
    if out.suffix == ".csv":
        out.parent.mkdir(parents=True, exist_ok=True)
        composed.to_csv(out, index=False)
        return out, None

    out.mkdir(parents=True, exist_ok=True)
    composed_csv = out / "composed.csv"
    composed.to_csv(composed_csv, index=False)

    ok = composed[composed["compose_status"] == "pass"].copy()
    summary_csv = out / "summary.csv"
    if ok.empty:
        pd.DataFrame(columns=["suite", "metric", "total_latency_us", "case_count"]).to_csv(summary_csv, index=False)
    else:
        ok["weighted_latency_us"] = pd.to_numeric(ok["weighted_latency_us"], errors="coerce").fillna(0.0)
        summary = (
            ok.groupby(["suite", "metric"], as_index=False, sort=True)
            .agg(total_latency_us=("weighted_latency_us", "sum"), case_count=("case_id", "count"))
        )
        summary.to_csv(summary_csv, index=False)
    return composed_csv, summary_csv


def compose_to_csv(suite: BenchSuite, options: ComposeOptions) -> tuple[Path, Path | None]:
    composed = compose_latency(suite, options)
    return write_compose_outputs(composed, options.out)
