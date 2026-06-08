from __future__ import annotations

import math
import re
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

import pandas as pd

from .suite import BenchSuite, resolve_case_fpga_bin, suite_to_rows


METRIC_COLUMNS = ("avg_us", "p50_us", "p95_us", "min_us", "max_us")
SELECT_POLICIES = ("median", "latest", "mean", "min", "strict")
MISSING_POLICIES = ("error", "nan", "skip")


@dataclass(frozen=True)
class LatencyScaleRule:
    name: str
    condition: Mapping[str, Any]
    scale: float


@dataclass(frozen=True)
class ComposeOptions:
    raw_dbs: tuple[Path, ...]
    out: Path
    metric: str = "p50_us"
    select: str = "median"
    missing: str = "error"
    fpga_bin_label: str | None = None
    xclbin_sha256: str | None = None
    match_fpga_bin: bool = True
    latency_scale_rules: tuple[LatencyScaleRule | Mapping[str, Any], ...] = ()


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


def _coerce_latency_scale_rule(rule: LatencyScaleRule | Mapping[str, Any], index: int) -> LatencyScaleRule:
    if isinstance(rule, LatencyScaleRule):
        out = rule
    elif isinstance(rule, Mapping):
        if "condition" not in rule or "scale" not in rule:
            raise ValueError("latency scale rule mapping must include condition and scale")
        out = LatencyScaleRule(
            name=str(rule.get("name") or f"rule_{index}"),
            condition=rule["condition"],
            scale=rule["scale"],
        )
    else:
        raise ValueError(f"unsupported latency scale rule type: {type(rule).__name__}")

    if not isinstance(out.condition, Mapping):
        raise ValueError(f"latency scale rule {out.name!r} condition must be a mapping")
    try:
        scale = float(out.scale)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"latency scale rule {out.name!r} scale must be numeric") from exc
    if not math.isfinite(scale) or scale <= 0.0:
        raise ValueError(f"latency scale rule {out.name!r} scale must be a positive finite value")
    return LatencyScaleRule(name=out.name or f"rule_{index}", condition=out.condition, scale=scale)


def _regex_mask(series: pd.Series, pattern: object) -> pd.Series:
    compiled = pattern if isinstance(pattern, re.Pattern) else re.compile(str(pattern))
    return series.astype(str).map(lambda value: bool(compiled.search(value)))


def _matcher_mask(series: pd.Series, matcher: object) -> pd.Series:
    if isinstance(matcher, Mapping):
        if set(matcher.keys()) == {"regex"}:
            return _regex_mask(series, matcher["regex"])
        raise ValueError("matcher mapping must be {'regex': pattern}")
    if isinstance(matcher, re.Pattern):
        return _regex_mask(series, matcher)
    if isinstance(matcher, (list, tuple, set, frozenset)):
        mask = pd.Series(False, index=series.index)
        for item in matcher:
            mask = mask | _matcher_mask(series, item)
        return mask
    return series.eq(matcher) | series.astype(str).eq(str(matcher))


def _scale_rule_mask(raw: pd.DataFrame, rule: LatencyScaleRule) -> pd.Series:
    mask = pd.Series(True, index=raw.index)
    for column, matcher in rule.condition.items():
        if column not in raw.columns:
            raise ValueError(f"latency scale rule {rule.name!r} references missing column: {column}")
        mask = mask & _matcher_mask(raw[column], matcher)
    return mask


def apply_latency_scale_rules(
    raw: pd.DataFrame,
    rules: tuple[LatencyScaleRule | Mapping[str, Any], ...],
    *,
    metric_columns: tuple[str, ...] = METRIC_COLUMNS,
) -> pd.DataFrame:
    if not rules:
        return raw.copy()

    out = raw.copy()
    metric_cols = [column for column in metric_columns if column in out.columns]
    if not metric_cols:
        raise ValueError("raw DB has no latency metric columns to scale")

    out["_latency_scale_factor"] = 1.0
    out["_latency_scale_rules"] = ""
    for index, raw_rule in enumerate(rules):
        rule = _coerce_latency_scale_rule(raw_rule, index)
        mask = _scale_rule_mask(out, rule)
        if not bool(mask.any()):
            continue
        out.loc[mask, "_latency_scale_factor"] = (
            pd.to_numeric(out.loc[mask, "_latency_scale_factor"], errors="coerce").fillna(1.0) * rule.scale
        )
        existing = out.loc[mask, "_latency_scale_rules"].astype(str)
        out.loc[mask, "_latency_scale_rules"] = existing.map(
            lambda value: f"{value};{rule.name}" if value else rule.name
        )

    scale = pd.to_numeric(out["_latency_scale_factor"], errors="coerce").fillna(1.0)
    for column in metric_cols:
        out[column] = pd.to_numeric(out[column], errors="coerce") * scale
    out["_latency_scale_factor"] = scale.map(lambda value: f"{float(value):.12g}")
    return out


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


def _match_key_columns(match_fpga_bin: bool) -> list[str]:
    columns = ["app", "_normalized_args"]
    if match_fpga_bin:
        columns.append("expected_fpga_bin_label")
    return columns


def _case_rows_with_match_keys(suite: BenchSuite, *, match_fpga_bin: bool) -> pd.DataFrame:
    rows = []
    for order, (case_obj, case) in enumerate(zip(suite.cases, suite_to_rows(suite))):
        row = dict(case)
        row["_case_order"] = order
        row["_normalized_args"] = normalize_args(str(row["args"]))
        row["app"] = str(row["app"])
        row["expected_fpga_bin_label"] = resolve_case_fpga_bin(suite, case_obj) if match_fpga_bin else ""
        rows.append(row)
    if not rows:
        return pd.DataFrame(columns=["_case_order", "_normalized_args", "app", "expected_fpga_bin_label"])
    return pd.DataFrame(rows)


def _raw_with_match_keys(raw: pd.DataFrame, *, match_fpga_bin: bool) -> pd.DataFrame:
    out = raw.copy()
    out["app"] = out["app"].astype(str)
    out["_normalized_args"] = out["args"].astype(str).map(normalize_args)
    if match_fpga_bin:
        out["expected_fpga_bin_label"] = out["fpga_bin_label"].astype(str)
    return out


def _raw_selection_row(
    key_values: tuple[object, ...],
    matches: pd.DataFrame,
    *,
    key_columns: list[str],
    metric: str,
    select: str,
) -> dict[str, Any]:
    value, selected = _select_value(matches, metric, select)
    row: dict[str, Any] = {
        column: value for column, value in zip(key_columns, key_values)
    }
    row.update(
        {
            "latency_us": value,
            "match_count": len(matches),
            "source_raw_dbs": _unique_join(matches["raw_db"]),
            "source_run_ids": _unique_join(matches["run_id"]) if "run_id" in matches.columns else "",
            "source_fpga_bin_labels": _unique_join(matches["fpga_bin_label"]) if "fpga_bin_label" in matches.columns else "",
            "source_xclbin_sha256s": _unique_join(matches["xclbin_sha256"]) if "xclbin_sha256" in matches.columns else "",
        }
    )
    if "_latency_scale_rules" in matches.columns:
        row["source_latency_scale_rules"] = _unique_join(matches["_latency_scale_rules"])
        row["source_latency_scales"] = _unique_join(matches["_latency_scale_factor"])
    if selected is not None:
        row["selected_run_id"] = str(selected.get("run_id", ""))
        row["selected_timestamp_utc"] = str(selected.get("timestamp_utc", ""))
    else:
        row["selected_run_id"] = ""
        row["selected_timestamp_utc"] = ""
    return row


def _first_case_id_for_key(cases: pd.DataFrame, key_columns: list[str], key_values: tuple[object, ...]) -> str:
    mask = pd.Series(True, index=cases.index)
    for column, value in zip(key_columns, key_values):
        mask = mask & cases[column].eq(value)
    matches = cases[mask]
    if matches.empty:
        return ""
    return str(matches.iloc[0].get("case_id", ""))


def _selected_raw_rows(
    raw: pd.DataFrame,
    cases: pd.DataFrame,
    *,
    key_columns: list[str],
    metric: str,
    select: str,
) -> pd.DataFrame:
    if raw.empty or cases.empty:
        return pd.DataFrame(columns=[*key_columns, "latency_us", "match_count"])

    used_keys = cases[key_columns].drop_duplicates()
    relevant = raw.merge(used_keys, on=key_columns, how="inner")
    if relevant.empty:
        return pd.DataFrame(columns=[*key_columns, "latency_us", "match_count"])

    rows = []
    group_columns = key_columns[0] if len(key_columns) == 1 else key_columns
    for raw_key, matches in relevant.groupby(group_columns, dropna=False, sort=False):
        key_values = raw_key if isinstance(raw_key, tuple) else (raw_key,)
        try:
            rows.append(
                _raw_selection_row(
                    key_values,
                    matches,
                    key_columns=key_columns,
                    metric=metric,
                    select=select,
                )
            )
        except ValueError as exc:
            case_id = _first_case_id_for_key(cases, key_columns, key_values)
            prefix = f"{case_id}: " if case_id else ""
            raise ValueError(f"{prefix}{exc}") from exc
    return pd.DataFrame(rows)


def _safe_str(value: object) -> str:
    return "" if pd.isna(value) else str(value)


def _compose_rows_from_merge(
    merged: pd.DataFrame,
    *,
    metric: str,
    select: str,
    missing: str,
    include_scale_columns: bool,
) -> pd.DataFrame:
    rows: list[dict[str, Any]] = []
    missing_cases: list[str] = []
    for _, merged_row in merged.sort_values("_case_order", kind="stable").iterrows():
        row = merged_row.to_dict()
        matched = not pd.isna(row.get("match_count"))
        case = {
            key: value
            for key, value in row.items()
            if key not in {"_case_order", "_normalized_args"}
        }
        if not matched:
            missing_cases.append(str(row.get("case_id", "")))
            if missing == "skip":
                continue
            if missing == "nan":
                case.update(
                    {
                        "metric": metric,
                        "latency_us": math.nan,
                        "weighted_latency_us": math.nan,
                        "match_count": 0,
                        "select_policy": select,
                        "compose_status": "missing",
                        "source_raw_dbs": "",
                        "source_run_ids": "",
                        "source_fpga_bin_labels": "",
                        "source_xclbin_sha256s": "",
                        "selected_run_id": "",
                        "selected_timestamp_utc": "",
                    }
                )
                if include_scale_columns:
                    case["source_latency_scale_rules"] = ""
                    case["source_latency_scales"] = ""
                rows.append(case)
            continue

        calls = float(row["calls_per_forward"])
        latency = float(row["latency_us"]) if not pd.isna(row["latency_us"]) else math.nan
        case.update(
            {
                "metric": metric,
                "latency_us": latency,
                "weighted_latency_us": latency * calls if not math.isnan(latency) else math.nan,
                "match_count": int(row["match_count"]),
                "select_policy": select,
                "compose_status": "pass",
                "source_raw_dbs": _safe_str(row.get("source_raw_dbs")),
                "source_run_ids": _safe_str(row.get("source_run_ids")),
                "source_fpga_bin_labels": _safe_str(row.get("source_fpga_bin_labels")),
                "source_xclbin_sha256s": _safe_str(row.get("source_xclbin_sha256s")),
                "selected_run_id": _safe_str(row.get("selected_run_id")),
                "selected_timestamp_utc": _safe_str(row.get("selected_timestamp_utc")),
            }
        )
        if include_scale_columns:
            case["source_latency_scale_rules"] = _safe_str(row.get("source_latency_scale_rules"))
            case["source_latency_scales"] = _safe_str(row.get("source_latency_scales"))
        rows.append(case)

    if missing_cases and missing == "error":
        preview = ", ".join(missing_cases[:10])
        suffix = "" if len(missing_cases) <= 10 else f", ... ({len(missing_cases)} total)"
        raise ValueError(f"raw DB is missing measurements for cases: {preview}{suffix}")
    return pd.DataFrame(rows)


def compose_latency(suite: BenchSuite, options: ComposeOptions) -> pd.DataFrame:
    if options.metric not in METRIC_COLUMNS:
        raise ValueError(f"metric must be one of {', '.join(METRIC_COLUMNS)}")
    if options.select not in SELECT_POLICIES:
        raise ValueError(f"select must be one of {', '.join(SELECT_POLICIES)}")
    if options.missing not in MISSING_POLICIES:
        raise ValueError(f"missing must be one of {', '.join(MISSING_POLICIES)}")

    raw = _read_raw_dbs(options.raw_dbs)
    _require_columns(raw, ["app", "args", "status", options.metric])
    if options.latency_scale_rules:
        raw = apply_latency_scale_rules(raw, options.latency_scale_rules)
    raw = raw[raw["status"].astype(str) == "pass"].copy()

    if options.match_fpga_bin:
        _require_columns(raw, ["fpga_bin_label"])
    if options.fpga_bin_label:
        _require_columns(raw, ["fpga_bin_label"])
        raw = raw[raw["fpga_bin_label"].astype(str) == options.fpga_bin_label].copy()
    if options.xclbin_sha256:
        _require_columns(raw, ["xclbin_sha256"])
        raw = raw[raw["xclbin_sha256"].astype(str) == options.xclbin_sha256].copy()

    cases = _case_rows_with_match_keys(suite, match_fpga_bin=options.match_fpga_bin)
    raw = _raw_with_match_keys(raw, match_fpga_bin=options.match_fpga_bin)
    key_columns = _match_key_columns(options.match_fpga_bin)
    selected_raw = _selected_raw_rows(
        raw,
        cases,
        key_columns=key_columns,
        metric=options.metric,
        select=options.select,
    )
    merged = cases.merge(selected_raw, on=key_columns, how="left", suffixes=("", "_raw"))
    return _compose_rows_from_merge(
        merged,
        metric=options.metric,
        select=options.select,
        missing=options.missing,
        include_scale_columns=bool(options.latency_scale_rules),
    )


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
