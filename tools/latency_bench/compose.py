from __future__ import annotations

import math
import re
import shlex
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

import pandas as pd

from .fpga_clock import DEFAULT_FPGA_PERIOD_S, resolve_fpga_period_s
from .suite import BenchCase, BenchSuite, make_exec_key, resolve_case_fpga_bin, suite_to_rows
from .interpolation import interpolation_group_key


METRIC_COLUMNS = (
    "avg_us", "p50_us", "p95_us", "min_us", "max_us",
    "fpga_cycle", "fpga_cycle_latency",
)
POWER_METRIC_COLUMNS = (
    "power_avg_w",
    "power_vcc_avg_w",
    "power_pcie_avg_w",
    "power_dynamic_avg_w",
)
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


def _require_xclbin_sha256(raw: pd.DataFrame) -> pd.DataFrame:
    _require_columns(raw, ["xclbin_sha256"])
    out = raw.copy()
    sha256 = out["xclbin_sha256"].fillna("").astype(str).str.strip()
    missing = sha256.eq("") | sha256.str.lower().eq("nan")
    if bool(missing.any()):
        locations = []
        for _, row in out.loc[missing].head(10).iterrows():
            raw_db = str(row.get("raw_db", ""))
            run_id = str(row.get("run_id", ""))
            locations.append(":".join(value for value in (raw_db, run_id) if value))
        preview = ", ".join(locations)
        suffix = "" if int(missing.sum()) <= 10 else f", ... ({int(missing.sum())} total)"
        raise ValueError(
            "raw DB contains missing xclbin_sha256"
            + (f": {preview}{suffix}" if preview else suffix)
        )
    out["xclbin_sha256"] = sha256
    return out


def _add_fpga_cycle_latency(raw: pd.DataFrame) -> pd.DataFrame:
    """Add cycle count, period, and cycle-derived latency in microseconds."""
    if "fpga_cycle" not in raw.columns:
        return raw.copy()
    out = raw.copy()
    representatives = out.drop_duplicates("xclbin_sha256", keep="first")
    period_by_sha256 = {
        str(row["xclbin_sha256"]): resolve_fpga_period_s(
            row.to_dict(), default=DEFAULT_FPGA_PERIOD_S
        )
        for _, row in representatives.iterrows()
    }
    out["fpga_period_s"] = pd.to_numeric(
        out["xclbin_sha256"].map(period_by_sha256), errors="coerce"
    )
    out["fpga_cycle"] = pd.to_numeric(out["fpga_cycle"], errors="coerce")
    out["fpga_cycle_latency"] = (
        out["fpga_cycle"] * out["fpga_period_s"] * 1_000_000.0
    )
    return out


def _filter_pass_raw_rows(raw: pd.DataFrame) -> pd.DataFrame:
    status = raw["status"].astype(str)
    keep = status.eq("pass")
    dropped = int((~keep).sum())
    if dropped:
        status_counts = status[~keep].value_counts(sort=False)
        status_summary = ", ".join(f"{value}={count}" for value, count in status_counts.items())
        warnings.warn(
            f"filtered out {dropped} raw DB row(s) with status != 'pass'"
            + (f": {status_summary}" if status_summary else ""),
            RuntimeWarning,
            stacklevel=2,
        )
    return raw.loc[keep].copy()


def _dedupe_latest_raw_rows(raw: pd.DataFrame, *, key_columns: list[str]) -> pd.DataFrame:
    if raw.empty:
        return raw.copy()

    duplicate_mask = raw.duplicated(subset=key_columns, keep=False)
    if not bool(duplicate_mask.any()):
        return raw.copy()

    duplicate_rows = int(duplicate_mask.sum())
    duplicate_keys = int(raw.loc[duplicate_mask, key_columns].drop_duplicates().shape[0])
    ordered = raw.copy()
    ordered["_raw_order"] = range(len(ordered))
    helper_columns = ["_raw_order"]
    if "timestamp_utc" in ordered.columns:
        ordered["_raw_timestamp_utc"] = pd.to_datetime(ordered["timestamp_utc"], errors="coerce", utc=True)
        helper_columns.append("_raw_timestamp_utc")
        ordered = ordered.sort_values(["_raw_timestamp_utc", "_raw_order"], kind="stable", na_position="first")
    else:
        ordered = ordered.sort_values("_raw_order", kind="stable")

    deduped = ordered.drop_duplicates(subset=key_columns, keep="last")
    deduped = deduped.sort_values("_raw_order", kind="stable").drop(columns=helper_columns)
    warnings.warn(
        f"found {duplicate_rows} duplicate raw DB row(s) across {duplicate_keys} "
        "(fpga_bin, app, args) key(s); using the most recent row",
        RuntimeWarning,
        stacklevel=2,
    )
    return deduped.reset_index(drop=True)


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
    if len(matches) == 1:
        row = matches.iloc[0]
        return float(pd.to_numeric(row[metric], errors="coerce")), row

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
        row["_normalized_args"] = normalize_args(
            str(row.get("measurement_args") or row["args"])
        )
        row["app"] = str(row["app"])
        row["exec_key"] = str(row["exec_key"])
        row["expected_fpga_bin_label"] = resolve_case_fpga_bin(suite, case_obj) if match_fpga_bin else ""
        rows.append(row)
    if not rows:
        return pd.DataFrame(columns=["_case_order", "_normalized_args", "app", "expected_fpga_bin_label"])
    return pd.DataFrame(rows)


def _raw_with_match_keys(raw: pd.DataFrame, *, match_fpga_bin: bool) -> pd.DataFrame:
    out = raw.copy()
    out["app"] = out["app"].astype(str)
    out["_normalized_args"] = out["args"].astype(str).map(normalize_args)
    shas = out["xclbin_sha256"] if "xclbin_sha256" in out.columns else ""
    if isinstance(shas, str):
        shas = pd.Series(shas, index=out.index)
    out["exec_key"] = [
        make_exec_key("" if pd.isna(sha) else sha, app, args)
        for sha, app, args in zip(shas, out["app"], out["_normalized_args"])
    ]
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
    for supplemental_metric in ("fpga_cycle", "fpga_cycle_latency", "fpga_period_s"):
        if supplemental_metric in matches.columns:
            row[supplemental_metric], _ = _select_value(
                matches, supplemental_metric, select
            )
    for power_metric in POWER_METRIC_COLUMNS:
        if power_metric in matches.columns:
            row[power_metric], _ = _select_value(matches, power_metric, select)
    if "_latency_scale_rules" in matches.columns:
        row["source_latency_scale_rules"] = _unique_join(matches["_latency_scale_rules"])
        row["source_latency_scales"] = _unique_join(matches["_latency_scale_factor"])
    if selected is not None:
        row["selected_run_id"] = str(selected.get("run_id", ""))
        row["selected_timestamp_utc"] = str(selected.get("timestamp_utc", ""))
        row["selected_exec_key"] = str(selected.get("exec_key", ""))
    else:
        row["selected_run_id"] = ""
        row["selected_timestamp_utc"] = ""
        exec_keys = matches["exec_key"].dropna().astype(str).unique().tolist()
        row["selected_exec_key"] = exec_keys[0] if len(exec_keys) == 1 else ""
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
        selected_exec_key = _safe_str(row.get("selected_exec_key"))
        if selected_exec_key:
            case["exec_key"] = selected_exec_key
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
                        "latency_resolution_kind": "missing",
                        "latency_interpolation_lower_case_id": "",
                        "latency_interpolation_upper_case_id": "",
                        "latency_interpolation_upper_ratio": math.nan,
                        "latency_reuse_representative_case_id": "",
                        "power_resolution_kind": "missing",
                        "power_interpolation_lower_case_id": "",
                        "power_interpolation_upper_case_id": "",
                        "power_interpolation_upper_ratio": math.nan,
                        "power_reuse_representative_case_id": "",
                    }
                )
                for power_metric in POWER_METRIC_COLUMNS:
                    case[power_metric] = math.nan
                if include_scale_columns:
                    case["source_latency_scale_rules"] = ""
                    case["source_latency_scales"] = ""
                rows.append(case)
            continue

        calls = float(row["calls_per_forward"])
        effective_calls = calls
        latency = float(row["latency_us"]) if not pd.isna(row["latency_us"]) else math.nan
        measurement_kind = str(row.get("measurement_kind", "measured"))
        resolution_kind = (
            "promoted" if measurement_kind == "interpolated"
            else measurement_kind
        )
        has_power = any(
            not pd.isna(row.get(power_metric))
            for power_metric in POWER_METRIC_COLUMNS
        )
        case.update(
            {
                "metric": metric,
                "latency_us": latency,
                "effective_calls": effective_calls,
                "weighted_latency_us": (
                    latency * effective_calls if not math.isnan(latency) else math.nan
                ),
                "match_count": int(row["match_count"]),
                "select_policy": select,
                "compose_status": "pass",
                "source_raw_dbs": _safe_str(row.get("source_raw_dbs")),
                "source_run_ids": _safe_str(row.get("source_run_ids")),
                "source_fpga_bin_labels": _safe_str(row.get("source_fpga_bin_labels")),
                "source_xclbin_sha256s": _safe_str(row.get("source_xclbin_sha256s")),
                "selected_run_id": _safe_str(row.get("selected_run_id")),
                "selected_timestamp_utc": _safe_str(row.get("selected_timestamp_utc")),
                "latency_resolution_kind": resolution_kind,
                "latency_interpolation_lower_case_id": "",
                "latency_interpolation_upper_case_id": "",
                "latency_interpolation_upper_ratio": math.nan,
                "latency_reuse_representative_case_id": "",
                "power_resolution_kind": resolution_kind if has_power else "missing",
                "power_interpolation_lower_case_id": "",
                "power_interpolation_upper_case_id": "",
                "power_interpolation_upper_ratio": math.nan,
                "power_reuse_representative_case_id": "",
            }
        )
        for power_metric in POWER_METRIC_COLUMNS:
            case[power_metric] = pd.to_numeric(
                row.get(power_metric), errors="coerce"
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


def _resolve_decode_reuse(
    composed: pd.DataFrame,
    suite: BenchSuite,
) -> pd.DataFrame:
    out = composed.reset_index(drop=True).copy()
    if out.empty:
        return out

    positions = {
        str(case_id): index
        for index, case_id in enumerate(out["case_id"].astype(str))
    }
    groups: dict[str, list[tuple[BenchCase, int]]] = {}
    for case in suite.cases:
        position = positions.get(case.case_id)
        if position is not None:
            groups.setdefault(interpolation_group_key(case), []).append((case, position))

    source_columns = (
        "match_count",
        "source_raw_dbs",
        "source_run_ids",
        "source_fpga_bin_labels",
        "source_xclbin_sha256s",
        "selected_run_id",
        "selected_timestamp_utc",
        "source_latency_scale_rules",
        "source_latency_scales",
    )
    for group in groups.values():
        by_step: dict[int, tuple[BenchCase, int]] = {
            int(case.output_token_index): (case, position)
            for case, position in group
            if int(case.output_token_index) > 0
        }
        for case, position in group:
            resolution_kind = str(case.measurement_kind)
            if resolution_kind not in {"invariant_reused", "bucket_reused"}:
                continue
            representative_step = int(case.shape.get("reuse_representative_step", 0))
            representative = by_step.get(representative_step)
            if representative is None:
                raise ValueError(
                    f"{case.case_id}: {resolution_kind} references missing "
                    f"output-token step {representative_step}"
                )
            representative_case, representative_position = representative

            # Record the logical dependency even when the representative itself
            # has no raw measurement.  Otherwise a reused row looks like an
            # unrelated missing case and the actual missing anchor is hidden.
            out.at[
                position, "latency_reuse_representative_case_id"
            ] = representative_case.case_id
            out.at[
                position, "power_reuse_representative_case_id"
            ] = representative_case.case_id

            representative_has_latency = not pd.isna(
                out.at[representative_position, "latency_us"]
            )
            if pd.isna(out.at[position, "latency_us"]) and representative_has_latency:
                latency = float(out.at[representative_position, "latency_us"])
                effective_calls = float(out.at[position, "calls_per_forward"])
                out.at[position, "latency_us"] = latency
                out.at[position, "effective_calls"] = effective_calls
                out.at[position, "weighted_latency_us"] = latency * effective_calls
                out.at[position, "compose_status"] = "pass"
                out.at[position, "latency_resolution_kind"] = resolution_kind
                for column in source_columns:
                    if column in out.columns:
                        out.at[position, column] = out.at[representative_position, column]

            copied_power = False
            for power_metric in POWER_METRIC_COLUMNS:
                if pd.isna(out.at[position, power_metric]) and not pd.isna(
                    out.at[representative_position, power_metric]
                ):
                    out.at[position, power_metric] = out.at[
                        representative_position, power_metric
                    ]
                    copied_power = True
            if copied_power:
                out.at[position, "power_resolution_kind"] = resolution_kind
    return out


def _resolve_decode_interpolation(
    composed: pd.DataFrame,
    suite: BenchSuite,
) -> pd.DataFrame:
    out = composed.reset_index(drop=True).copy()
    if out.empty:
        return out

    positions = {
        str(case_id): index
        for index, case_id in enumerate(out["case_id"].astype(str))
    }
    groups: dict[str, list[tuple[BenchCase, int]]] = {}
    for case in suite.cases:
        position = positions.get(case.case_id)
        if position is None:
            continue
        groups.setdefault(interpolation_group_key(case), []).append((case, position))

    for group in groups.values():
        if not any(
            case.shape.get("decode_sampling_class") == "continuous"
            for case, _ in group
        ):
            continue
        ordered = sorted(
            group,
            key=lambda item: int(
                item[0].output_token_index
                or item[0].shape.get("logical_cache_length", 0)
            ),
        )
        anchors = [
            (case, position)
            for case, position in ordered
            if not pd.isna(out.at[position, "latency_us"])
        ]
        if not anchors:
            continue
        for case, position in ordered:
            if str(case.measurement_kind) != "interpolated":
                continue
            if not pd.isna(out.at[position, "latency_us"]):
                out.at[position, "latency_resolution_kind"] = "promoted"
                continue
            target = int(
                case.output_token_index
                or case.shape.get("logical_cache_length", 0)
            )
            lower = [
                item for item in anchors
                if int(item[0].output_token_index or item[0].shape.get("logical_cache_length", 0))
                <= target
            ]
            upper = [
                item for item in anchors
                if int(item[0].output_token_index or item[0].shape.get("logical_cache_length", 0))
                >= target
            ]
            lo_case, lo_pos = lower[-1] if lower else anchors[0]
            hi_case, hi_pos = upper[0] if upper else anchors[-1]
            lo_x = int(
                lo_case.output_token_index
                or lo_case.shape.get("logical_cache_length", 0)
            )
            hi_x = int(
                hi_case.output_token_index
                or hi_case.shape.get("logical_cache_length", 0)
            )
            ratio = 0.0 if lo_x == hi_x else (target - lo_x) / (hi_x - lo_x)
            lo_value = float(out.at[lo_pos, "latency_us"])
            hi_value = float(out.at[hi_pos, "latency_us"])
            latency = lo_value * (1.0 - ratio) + hi_value * ratio
            effective_calls = float(out.at[position, "calls_per_forward"])
            out.at[position, "latency_us"] = latency
            out.at[position, "effective_calls"] = effective_calls
            out.at[position, "weighted_latency_us"] = latency * effective_calls
            out.at[position, "compose_status"] = "estimated"
            out.at[position, "latency_resolution_kind"] = "interpolated"
            out.at[position, "latency_interpolation_lower_case_id"] = lo_case.case_id
            out.at[position, "latency_interpolation_upper_case_id"] = hi_case.case_id
            out.at[position, "latency_interpolation_upper_ratio"] = ratio
            out.at[position, "source_raw_dbs"] = _unique_join(pd.Series([
                out.at[lo_pos, "source_raw_dbs"],
                out.at[hi_pos, "source_raw_dbs"],
            ]))
            out.at[position, "source_run_ids"] = _unique_join(pd.Series([
                out.at[lo_pos, "source_run_ids"],
                out.at[hi_pos, "source_run_ids"],
            ]))

        for power_metric in POWER_METRIC_COLUMNS:
            power_anchors = [
                (case, position)
                for case, position in ordered
                if not pd.isna(out.at[position, power_metric])
            ]
            if not power_anchors:
                continue
            for case, position in ordered:
                if str(case.measurement_kind) != "interpolated":
                    continue
                if not pd.isna(out.at[position, power_metric]):
                    out.at[position, "power_resolution_kind"] = "promoted"
                    continue
                target = int(
                    case.output_token_index
                    or case.shape.get("logical_cache_length", 0)
                )
                lower = [
                    item for item in power_anchors
                    if int(
                        item[0].output_token_index
                        or item[0].shape.get("logical_cache_length", 0)
                    ) <= target
                ]
                upper = [
                    item for item in power_anchors
                    if int(
                        item[0].output_token_index
                        or item[0].shape.get("logical_cache_length", 0)
                    ) >= target
                ]
                lo_case, lo_pos = lower[-1] if lower else power_anchors[0]
                hi_case, hi_pos = upper[0] if upper else power_anchors[-1]
                lo_x = int(
                    lo_case.output_token_index
                    or lo_case.shape.get("logical_cache_length", 0)
                )
                hi_x = int(
                    hi_case.output_token_index
                    or hi_case.shape.get("logical_cache_length", 0)
                )
                ratio = 0.0 if lo_x == hi_x else (target - lo_x) / (hi_x - lo_x)
                lo_value = float(out.at[lo_pos, power_metric])
                hi_value = float(out.at[hi_pos, power_metric])
                out.at[position, power_metric] = (
                    lo_value * (1.0 - ratio) + hi_value * ratio
                )
                out.at[position, "power_resolution_kind"] = "interpolated"
                if not out.at[position, "power_interpolation_lower_case_id"]:
                    out.at[
                        position, "power_interpolation_lower_case_id"
                    ] = lo_case.case_id
                    out.at[
                        position, "power_interpolation_upper_case_id"
                    ] = hi_case.case_id
                    out.at[
                        position, "power_interpolation_upper_ratio"
                    ] = ratio
    return out


def _apply_missing_policy(
    composed: pd.DataFrame,
    missing: str,
) -> pd.DataFrame:
    missing_mask = pd.to_numeric(
        composed.get("latency_us"), errors="coerce"
    ).isna()
    if not bool(missing_mask.any()):
        return composed
    missing_ids = composed.loc[missing_mask, "case_id"].astype(str).tolist()
    if missing == "error":
        preview = ", ".join(missing_ids[:10])
        suffix = "" if len(missing_ids) <= 10 else f", ... ({len(missing_ids)} total)"
        raise ValueError(f"raw DB is missing measurements for cases: {preview}{suffix}")
    if missing == "skip":
        return composed.loc[~missing_mask].reset_index(drop=True)
    return composed


def _synchronize_fpga_cycle_metrics(composed: pd.DataFrame) -> pd.DataFrame:
    """Keep cycle count and cycle-derived microsecond latency explicit."""
    if "metric" not in composed.columns:
        return composed
    cycle_metric = composed["metric"].astype(str).isin(
        {"fpga_cycle", "fpga_cycle_latency"}
    )
    if not bool(cycle_metric.any()):
        return composed

    out = composed.copy()
    for column in ("fpga_cycle", "fpga_cycle_latency", "fpga_period_s"):
        if column not in out.columns:
            out[column] = math.nan
    periods = pd.to_numeric(out["fpga_period_s"], errors="coerce")
    unresolved = cycle_metric & (periods.isna() | periods.le(0.0))
    if bool(unresolved.any()):
        periods.loc[unresolved] = [
            resolve_fpga_period_s(row, default=DEFAULT_FPGA_PERIOD_S)
            for row in out.loc[unresolved].to_dict(orient="records")
        ]
    out.loc[cycle_metric, "fpga_period_s"] = periods.loc[cycle_metric]

    latency = pd.to_numeric(out["latency_us"], errors="coerce")
    cycles = pd.to_numeric(out["fpga_cycle"], errors="coerce")
    is_cycle = out["metric"].astype(str).eq("fpga_cycle")
    cycles = cycles.where(~is_cycle, latency)
    derived_latency = cycles * periods * 1_000_000.0
    is_cycle_latency = out["metric"].astype(str).eq("fpga_cycle_latency")
    derived_latency = derived_latency.where(~is_cycle_latency, latency)
    missing_cycles = cycle_metric & cycles.isna() & derived_latency.notna()
    cycles.loc[missing_cycles] = (
        derived_latency.loc[missing_cycles]
        / (periods.loc[missing_cycles] * 1_000_000.0)
    )
    out.loc[cycle_metric, "fpga_cycle"] = cycles.loc[cycle_metric]
    out.loc[cycle_metric, "fpga_cycle_latency"] = derived_latency.loc[cycle_metric]
    return out


def compose_latency(suite: BenchSuite, options: ComposeOptions) -> pd.DataFrame:
    if options.metric not in METRIC_COLUMNS:
        raise ValueError(f"metric must be one of {', '.join(METRIC_COLUMNS)}")
    if options.select not in SELECT_POLICIES:
        raise ValueError(f"select must be one of {', '.join(SELECT_POLICIES)}")
    if options.missing not in MISSING_POLICIES:
        raise ValueError(f"missing must be one of {', '.join(MISSING_POLICIES)}")

    raw = _read_raw_dbs(options.raw_dbs)
    _require_columns(raw, ["exec_key", "app", "args", "status"])
    raw = _require_xclbin_sha256(raw)
    raw = _add_fpga_cycle_latency(raw)
    _require_columns(raw, [options.metric])
    raw = _filter_pass_raw_rows(raw)
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
    raw = _dedupe_latest_raw_rows(raw, key_columns=key_columns)
    if options.latency_scale_rules:
        raw = apply_latency_scale_rules(raw, options.latency_scale_rules)
    selected_raw = _selected_raw_rows(
        raw,
        cases,
        key_columns=key_columns,
        metric=options.metric,
        select=options.select,
    )
    merged = cases.merge(selected_raw, on=key_columns, how="left", suffixes=("", "_raw"))
    composed = _compose_rows_from_merge(
        merged,
        metric=options.metric,
        select=options.select,
        missing="nan",
        include_scale_columns=bool(options.latency_scale_rules),
    )
    composed = _resolve_decode_reuse(composed, suite)
    composed = _resolve_decode_interpolation(composed, suite)
    composed = _synchronize_fpga_cycle_metrics(composed)
    return _apply_missing_policy(composed, options.missing)


def write_compose_outputs(composed: pd.DataFrame, out: Path) -> tuple[Path, Path | None]:
    if out.suffix == ".csv":
        out.parent.mkdir(parents=True, exist_ok=True)
        composed.to_csv(out, index=False)
        return out, None

    out.mkdir(parents=True, exist_ok=True)
    composed_csv = out / "composed.csv"
    composed.to_csv(composed_csv, index=False)

    ok = composed[
        composed["compose_status"].isin({"pass", "estimated"})
    ].copy()
    summary_csv = out / "summary.csv"
    if ok.empty:
        pd.DataFrame(columns=[
            "suite", "metric", "total_latency_us",
            "out_tokens", "avg_per_output_token_us", "case_count",
        ]).to_csv(summary_csv, index=False)
    else:
        ok["weighted_latency_us"] = pd.to_numeric(ok["weighted_latency_us"], errors="coerce").fillna(0.0)
        summary = (
            ok.groupby(["suite", "metric"], as_index=False, sort=True)
            .agg(total_latency_us=("weighted_latency_us", "sum"), case_count=("case_id", "count"))
        )
        output_meta: dict[tuple[str, str], tuple[int, float]] = {}
        for keys, sub in ok.groupby(["suite", "metric"], sort=True):
            only_generation = set(sub["stage"].astype(str)) == {"generation"}
            counts = {
                int(value)
                for value in pd.to_numeric(sub["out_tokens"], errors="coerce").dropna()
                if int(value) > 0
            } if only_generation else set()
            output_tokens = next(iter(counts)) if len(counts) == 1 else 0
            total = float(pd.to_numeric(sub["weighted_latency_us"], errors="coerce").fillna(0.0).sum())
            output_meta[keys] = (
                output_tokens,
                total / output_tokens if output_tokens > 0 else float("nan"),
            )
        summary["out_tokens"] = [
            output_meta[(row.suite, row.metric)][0] for row in summary.itertuples()
        ]
        summary["avg_per_output_token_us"] = [
            output_meta[(row.suite, row.metric)][1] for row in summary.itertuples()
        ]
        summary.to_csv(summary_csv, index=False)
    return composed_csv, summary_csv


def compose_to_csv(suite: BenchSuite, options: ComposeOptions) -> tuple[Path, Path | None]:
    composed = compose_latency(suite, options)
    return write_compose_outputs(composed, options.out)
