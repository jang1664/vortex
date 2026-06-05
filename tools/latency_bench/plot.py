from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Iterable, Mapping

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch, Rectangle
import pandas as pd

from .compose import ComposeOptions, LatencyScaleRule, compose_latency, normalize_args
from .suite import BenchCase, BenchDefaults, BenchSuite, resolve_case_fpga_bin


BAR_AXIS_COLUMNS = ("stage", "seq_len", "batch", "variant")
BAR_AXIS_CHOICES = (*BAR_AXIS_COLUMNS, "none")
STACK_BY_COLUMNS = ("name", "case_id", "kind", "backend", "op", "app")
DEFAULT_BAR_X = "seq_len"
DEFAULT_BAR_HUE = "variant"
DEFAULT_BAR_ROW = "stage"
DEFAULT_BAR_COL = "batch"
DEFAULT_STACK_BY = "name"
DEFAULT_RELATIVE_SCOPE = "global"
DEFAULT_LEGEND_POSITION = "right"
DEFAULT_STACK_LEGEND_SCOPE = "global"
_NONE_AXIS = "none"
RELATIVE_SCOPE_CHOICES = ("global", "subplot", "x_tick")
LEGEND_POSITION_CHOICES = ("right", "bottom", "top", "none")
STACK_LEGEND_SCOPE_CHOICES = ("global", "hue")
BLUE_GREEN_PALETTE = (
    "#0b3d91",
    "#006d77",
    "#2a9d8f",
    "#1b7f3a",
    "#4ea8de",
    "#52b788",
    "#184e77",
    "#40916c",
    "#76c893",
    "#168aad",
)
HUE_STACK_CMAPS = (
    "Blues",
    "Greens",
    "Oranges",
    "Purples",
    "Reds",
    "Greys",
    "YlGnBu",
    "PuBuGn",
    "YlOrBr",
    "PuRd",
)


@dataclass(frozen=True)
class SuiteBarPlotOptions:
    raw_dbs: tuple[Path, ...]
    out_dir: Path
    metric: str = "p50_us"
    select: str = "median"
    missing: str = "nan"
    x: str = DEFAULT_BAR_X
    hue: str | None = DEFAULT_BAR_HUE
    row: str | None = DEFAULT_BAR_ROW
    col: str | None = DEFAULT_BAR_COL
    stacked: bool = True
    stack_by: str = DEFAULT_STACK_BY
    value_labels: bool = True
    relative: bool = False
    relative_scope: str = DEFAULT_RELATIVE_SCOPE
    share_y: bool = False
    fpga_bin_label: str | None = None
    xclbin_sha256: str | None = None
    match_fpga_bin: bool = True
    legend_position: str = DEFAULT_LEGEND_POSITION
    legend_ncol: int | None = None
    stack_legend_scope: str = DEFAULT_STACK_LEGEND_SCOPE
    figure_title: str | None = None
    subplot_title_template: str | None = None
    x_label: str | None = None
    y_label: str | None = None
    legend_title: str | None = None
    axis_label_map: Mapping[str, str] = field(default_factory=dict)
    label_maps: Mapping[str, Mapping[object, str]] = field(default_factory=dict)
    value_orders: Mapping[str, Iterable[object]] = field(default_factory=dict)
    latency_scale_rules: tuple[LatencyScaleRule | Mapping[str, object], ...] = ()


@dataclass(frozen=True)
class SuiteBarData:
    composed: pd.DataFrame
    plot_data: pd.DataFrame
    stack_data: pd.DataFrame


def _save(fig, out_dir: Path, name: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_dir / f"{name}.png", dpi=180)
    fig.savefig(out_dir / f"{name}.pdf")
    plt.close(fig)


def _successful(results: pd.DataFrame) -> pd.DataFrame:
    ok = results[results["status"] == "pass"].copy()
    for col in ("p50_us", "avg_us", "p95_us", "calls_per_forward"):
        ok[col] = pd.to_numeric(ok[col], errors="coerce").fillna(0.0)
    return ok


def plot_case_latency(results: pd.DataFrame, out_dir: Path) -> None:
    ok = _successful(results).sort_values("p50_us", ascending=True)
    if ok.empty:
        return
    height = max(4.0, min(18.0, 0.32 * len(ok) + 1.8))
    fig, ax = plt.subplots(figsize=(10.5, height))
    ax.barh(ok["case_id"], ok["p50_us"], color="#2f6f73")
    ax.set_xlabel("p50 latency (us)")
    ax.set_ylabel("case")
    ax.set_title("Per-case FPGA latency")
    ax.grid(axis="x", alpha=0.25)
    _save(fig, out_dir, "case_latency_p50")


def plot_weighted_breakdown(results: pd.DataFrame, out_dir: Path, group_col: str, name: str) -> None:
    ok = _successful(results)
    if ok.empty:
        return
    ok["weighted_p50_us"] = ok["p50_us"] * ok["calls_per_forward"]
    group = ok.groupby(group_col, sort=True)["weighted_p50_us"].sum().sort_values(ascending=False)
    if group.empty:
        return
    fig, ax = plt.subplots(figsize=(10.5, max(4.0, min(12.0, 0.4 * len(group) + 1.8))))
    ax.barh(group.index.astype(str), group.values, color="#9a5b2f")
    ax.invert_yaxis()
    ax.set_xlabel("weighted p50 latency (us)")
    ax.set_ylabel(group_col)
    ax.set_title(f"Forward-pass weighted latency by {group_col}")
    ax.grid(axis="x", alpha=0.25)
    _save(fig, out_dir, name)


def plot_status(results: pd.DataFrame, out_dir: Path) -> None:
    counts = results["status"].fillna("unknown").value_counts().sort_index()
    fig, ax = plt.subplots(figsize=(6.5, 4.0))
    ax.bar(counts.index.astype(str), counts.values, color="#4a677d")
    ax.set_ylabel("case count")
    ax.set_title("Benchmark status")
    ax.grid(axis="y", alpha=0.25)
    _save(fig, out_dir, "status_summary")


def visualize(results_csv: Path, out_dir: Path) -> None:
    results = pd.read_csv(results_csv)
    plot_case_latency(results, out_dir)
    plot_weighted_breakdown(results, out_dir, "name", "weighted_by_kernel")
    plot_weighted_breakdown(results, out_dir, "kind", "weighted_by_kind")
    plot_status(results, out_dir)
    print(f"wrote figures to {out_dir}")


def _case_dedupe_key(case: BenchCase) -> tuple[object, ...]:
    return (
        case.case_id,
        case.app,
        normalize_args(case.args),
        case.variant,
        case.stage,
        case.name,
        case.calls_per_forward,
        case.warmup,
        case.iterations,
        case.fpga_bin,
    )


def _unique_join(values: Iterable[str]) -> str:
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        text = str(value)
        if not text or text in seen:
            continue
        seen.add(text)
        out.append(text)
    return ";".join(out)


def _combine_suites(suites: list[BenchSuite], *, match_fpga_bin: bool = True) -> tuple[BenchSuite, dict[str, str]]:
    if not suites:
        raise ValueError("at least one suite is required")

    cases: list[BenchCase] = []
    seen: set[tuple[object, ...]] = set()
    source_suites: dict[str, list[str]] = {}
    for suite in suites:
        for case in suite.cases:
            if match_fpga_bin:
                case = replace(case, fpga_bin=resolve_case_fpga_bin(suite, case))
            key = _case_dedupe_key(case)
            source_suites.setdefault(case.case_id, []).append(suite.name)
            if key in seen:
                continue
            seen.add(key)
            cases.append(case)

    name = "_".join(suite.name for suite in suites)
    if len(name) > 120:
        name = f"combined_{len(suites)}_suites"
    source_map = {
        case_id: _unique_join(names)
        for case_id, names in source_suites.items()
    }
    return BenchSuite(name=name, defaults=BenchDefaults(), cases=cases), source_map


def _shape_from_row(row: pd.Series) -> dict[str, object]:
    raw = row.get("shape_json", "")
    if not raw or pd.isna(raw):
        return {}
    try:
        value = json.loads(str(raw))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _int_or_none(value: object) -> int | None:
    if value is None or pd.isna(value):
        return None
    if isinstance(value, bool):
        return None
    try:
        return int(float(str(value)))
    except (TypeError, ValueError):
        return None


def _regex_int(text: object, patterns: tuple[str, ...]) -> int | None:
    value = str(text or "")
    for pattern in patterns:
        match = re.search(pattern, value)
        if match:
            return int(match.group(1))
    return None


def _derive_batch(row: pd.Series, shape: dict[str, object]) -> int | str:
    for key in ("batch", "B"):
        found = _int_or_none(shape.get(key))
        if found is not None:
            return found
    found = _regex_int(row.get("case_id", ""), (r"(?:^|_)batch(\d+)(?:_|$)", r"(?:^|_)b(\d+)(?:_|$)"))
    return found if found is not None else "unknown"


def _derive_seq_len(row: pd.Series, shape: dict[str, object]) -> int | str:
    stage = str(row.get("stage", ""))
    case_id = row.get("case_id", "")
    if stage == "generation":
        for key in ("seq_len", "gen_kv_len", "cache_len", "seqk"):
            found = _int_or_none(shape.get(key))
            if found is not None:
                return found
        found = _regex_int(case_id, (r"(?:^|_)gen_kv_len(\d+)(?:_|$)",))
        if found is not None:
            return found

    for key in ("seq_len", "prefill_seq_len", "seq", "seqq", "seqk", "gen_kv_len"):
        found = _int_or_none(shape.get(key))
        if found is not None:
            return found
    found = _regex_int(
        case_id,
        (
            r"(?:^|_)prefill_seq_len(\d+)(?:_|$)",
            r"(?:^|_)gen_kv_len(\d+)(?:_|$)",
            r"(?:^|_)seq(\d+)(?:_|$)",
            r"(?:^|_)s(\d+)(?:_|$)",
        ),
    )
    if found is not None:
        return found
    cache_len = _int_or_none(shape.get("cache_len"))
    return cache_len if cache_len is not None else "unknown"


def _add_bar_axis_columns(composed: pd.DataFrame, source_suites: dict[str, str]) -> pd.DataFrame:
    rows = composed.copy()
    batches: list[int | str] = []
    seq_lens: list[int | str] = []
    for _, row in rows.iterrows():
        shape = _shape_from_row(row)
        batches.append(_derive_batch(row, shape))
        seq_lens.append(_derive_seq_len(row, shape))
    rows["batch"] = batches
    rows["seq_len"] = seq_lens
    rows["source_suites"] = rows["case_id"].astype(str).map(source_suites).fillna("")
    return rows


def _stack_key(row: pd.Series, stack_by: str) -> str:
    if stack_by not in STACK_BY_COLUMNS:
        raise ValueError(f"unsupported stack-by field: {stack_by}")
    value = row.get(stack_by, "")
    text = "" if pd.isna(value) else str(value)
    return text or str(row.get("case_id", "case"))


def prepare_suite_bar_data(
    suites: list[BenchSuite],
    options: SuiteBarPlotOptions,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    combined_suite, source_suites = _combine_suites(suites, match_fpga_bin=options.match_fpga_bin)
    composed = compose_latency(
        combined_suite,
        ComposeOptions(
            raw_dbs=options.raw_dbs,
            out=options.out_dir,
            metric=options.metric,
            select=options.select,
            missing=options.missing,
            fpga_bin_label=options.fpga_bin_label,
            xclbin_sha256=options.xclbin_sha256,
            match_fpga_bin=options.match_fpga_bin,
            latency_scale_rules=options.latency_scale_rules,
        ),
    )
    composed = _add_bar_axis_columns(composed, source_suites)
    composed["weighted_latency_us"] = pd.to_numeric(composed["weighted_latency_us"], errors="coerce")
    composed["_weighted_latency_filled"] = composed["weighted_latency_us"].fillna(0.0)
    composed["stack_key"] = composed.apply(lambda row: _stack_key(row, options.stack_by), axis=1)

    plot_aggs = dict(
        total_latency_us=("_weighted_latency_filled", "sum"),
        case_count=("case_id", "count"),
        pass_case_count=("compose_status", lambda values: int((values.astype(str) == "pass").sum())),
        missing_case_count=("compose_status", lambda values: int((values.astype(str) != "pass").sum())),
        source_suites=("source_suites", lambda values: _unique_join(values.astype(str))),
        source_raw_dbs=("source_raw_dbs", lambda values: _unique_join(values.astype(str))),
        expected_fpga_bin_labels=("expected_fpga_bin_label", lambda values: _unique_join(values.astype(str))),
        source_fpga_bin_labels=("source_fpga_bin_labels", lambda values: _unique_join(values.astype(str))),
    )
    stack_aggs = dict(
        total_latency_us=("_weighted_latency_filled", "sum"),
        case_count=("case_id", "count"),
        pass_case_count=("compose_status", lambda values: int((values.astype(str) == "pass").sum())),
        missing_case_count=("compose_status", lambda values: int((values.astype(str) != "pass").sum())),
        source_cases=("case_id", lambda values: _unique_join(values.astype(str))),
        source_suites=("source_suites", lambda values: _unique_join(values.astype(str))),
        source_raw_dbs=("source_raw_dbs", lambda values: _unique_join(values.astype(str))),
        expected_fpga_bin_labels=("expected_fpga_bin_label", lambda values: _unique_join(values.astype(str))),
        source_fpga_bin_labels=("source_fpga_bin_labels", lambda values: _unique_join(values.astype(str))),
    )
    if "source_latency_scale_rules" in composed.columns:
        scale_aggs = dict(
            source_latency_scale_rules=("source_latency_scale_rules", lambda values: _unique_join(values.astype(str))),
            source_latency_scales=("source_latency_scales", lambda values: _unique_join(values.astype(str))),
        )
        plot_aggs.update(scale_aggs)
        stack_aggs.update(scale_aggs)

    plot_data = (
        composed.groupby(list(BAR_AXIS_COLUMNS), dropna=False, as_index=False, sort=True)
        .agg(**plot_aggs)
    )
    plot_data.insert(0, "metric", options.metric)

    stack_data = (
        composed.groupby([*BAR_AXIS_COLUMNS, "stack_key"], dropna=False, as_index=False, sort=True)
        .agg(**stack_aggs)
    )
    stack_data.insert(0, "metric", options.metric)
    return composed.drop(columns=["_weighted_latency_filled"]), plot_data, stack_data


def prepare_suite_bar_data_versions(
    suites: list[BenchSuite],
    options: SuiteBarPlotOptions,
) -> tuple[SuiteBarData, SuiteBarData | None]:
    if not options.latency_scale_rules:
        return SuiteBarData(*prepare_suite_bar_data(suites, options)), None

    unscaled_options = replace(options, latency_scale_rules=())
    unscaled = SuiteBarData(*prepare_suite_bar_data(suites, unscaled_options))
    scaled = SuiteBarData(*prepare_suite_bar_data(suites, options))
    return unscaled, scaled


def write_suite_bar_data_csvs(data: SuiteBarData, out_dir: Path, *, suffix: str = "") -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    data.composed.to_csv(out_dir / f"composed_cases{suffix}.csv", index=False)
    data.plot_data.to_csv(out_dir / f"plot_data{suffix}.csv", index=False)
    data.stack_data.to_csv(out_dir / f"plot_stack_data{suffix}.csv", index=False)


def _normalize_axis(value: str | None) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return None if text == _NONE_AXIS or not text else text


def _validate_bar_axes(options: SuiteBarPlotOptions) -> tuple[str, str | None, str | None, str | None]:
    axes = (options.x, options.hue, options.row, options.col)
    normalized = tuple(_normalize_axis(axis) for axis in axes)
    x, hue, row, col = normalized
    if x is None:
        raise ValueError("--x cannot be none")
    invalid = [axis for axis in normalized if axis is not None and axis not in BAR_AXIS_COLUMNS]
    if invalid:
        raise ValueError(f"unsupported plot axis: {', '.join(invalid)}")
    used = [axis for axis in normalized if axis is not None]
    if len(set(used)) != len(used):
        raise ValueError(f"plot axes must be distinct, got: {', '.join(used)}")
    return x, hue, row, col


def _validate_bar_options(options: SuiteBarPlotOptions) -> None:
    if options.relative_scope not in RELATIVE_SCOPE_CHOICES:
        raise ValueError(
            f"unsupported relative scope: {options.relative_scope}; "
            f"expected one of {', '.join(RELATIVE_SCOPE_CHOICES)}"
        )
    if options.legend_position not in LEGEND_POSITION_CHOICES:
        raise ValueError(
            f"unsupported legend position: {options.legend_position}; "
            f"expected one of {', '.join(LEGEND_POSITION_CHOICES)}"
        )
    if options.stack_legend_scope not in STACK_LEGEND_SCOPE_CHOICES:
        raise ValueError(
            f"unsupported stack legend scope: {options.stack_legend_scope}; "
            f"expected one of {', '.join(STACK_LEGEND_SCOPE_CHOICES)}"
        )
    if options.legend_ncol is not None and options.legend_ncol <= 0:
        raise ValueError("legend_ncol must be positive when set")


def _sort_key(value: object) -> tuple[int, float | str]:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return (2, "")
    try:
        return (0, float(str(value)))
    except ValueError:
        return (1, str(value))


def _values_match(left: object, right: object) -> bool:
    if left == right:
        return True
    return str(left) == str(right)


def _explicit_value_order(
    values: list[object],
    axis: str | None,
    options: SuiteBarPlotOptions | None,
) -> list[object] | None:
    if axis is None or options is None:
        return None
    explicit = options.value_orders.get(axis)
    if explicit is None and axis == "stack_key":
        explicit = options.value_orders.get(options.stack_by)
    if explicit is None:
        return None

    ordered: list[object] = []
    used = [False] * len(values)
    for requested in explicit:
        for idx, value in enumerate(values):
            if used[idx] or not _values_match(value, requested):
                continue
            ordered.append(value)
            used[idx] = True
            break
    rest = sorted((value for idx, value in enumerate(values) if not used[idx]), key=_sort_key)
    return [*ordered, *rest]


def _ordered_values(
    series: pd.Series,
    axis: str | None = None,
    options: SuiteBarPlotOptions | None = None,
) -> list[object]:
    values = series.drop_duplicates().tolist()
    explicit = _explicit_value_order(values, axis, options)
    if explicit is not None:
        return explicit
    if values and all(str(value) in {"prefill", "generation"} for value in values):
        order = {"prefill": 0, "generation": 1}
        return sorted(values, key=lambda value: order[str(value)])
    return sorted(values, key=_sort_key)


def _aggregate_for_axes(plot_data: pd.DataFrame, axes: tuple[str, ...]) -> pd.DataFrame:
    return (
        plot_data.groupby(list(axes), dropna=False, as_index=False, sort=True)
        .agg(
            total_latency_us=("total_latency_us", "sum"),
            case_count=("case_count", "sum"),
            pass_case_count=("pass_case_count", "sum"),
            missing_case_count=("missing_case_count", "sum"),
        )
    )


def _aggregate_stack_for_axes(stack_data: pd.DataFrame, axes: tuple[str, ...]) -> pd.DataFrame:
    return (
        stack_data.groupby([*axes, "stack_key"], dropna=False, as_index=False, sort=True)
        .agg(
            total_latency_us=("total_latency_us", "sum"),
            case_count=("case_count", "sum"),
            pass_case_count=("pass_case_count", "sum"),
            missing_case_count=("missing_case_count", "sum"),
        )
    )


def _series_relative_baseline(values: pd.Series) -> float:
    values = pd.to_numeric(values, errors="coerce").fillna(0.0)
    positive = values[values > 0]
    return float(positive.min()) if not positive.empty else 1.0


def _relative_group_axes(scope: str, x: str, row: str | None, col: str | None) -> tuple[str, ...]:
    if scope == "global":
        return ()
    if scope == "subplot":
        return tuple(axis for axis in (row, col) if axis is not None)
    if scope == "x_tick":
        return tuple(axis for axis in (row, col, x) if axis is not None)
    raise ValueError(f"unsupported relative scope: {scope}")


def _relative_baselines(rows: pd.DataFrame, value_col: str, group_axes: tuple[str, ...]) -> pd.DataFrame:
    baseline_col = "_relative_baseline"
    if not group_axes:
        return pd.DataFrame({baseline_col: [_series_relative_baseline(rows[value_col])]})
    return (
        rows.groupby(list(group_axes), dropna=False, as_index=False, sort=True)[value_col]
        .agg(_series_relative_baseline)
        .rename(columns={value_col: baseline_col})
    )


def _apply_relative_values(
    rows: pd.DataFrame,
    value_col: str,
    baselines: pd.DataFrame,
    group_axes: tuple[str, ...],
) -> pd.DataFrame:
    out = rows.copy()
    values = pd.to_numeric(out[value_col], errors="coerce").fillna(0.0)
    if group_axes:
        out = out.merge(baselines, on=list(group_axes), how="left")
        baseline_values = pd.to_numeric(out["_relative_baseline"], errors="coerce").fillna(1.0)
    else:
        baseline_values = pd.Series(float(baselines.loc[0, "_relative_baseline"]), index=out.index)
    baseline_values = baseline_values.mask(baseline_values <= 0, 1.0)
    out[value_col] = values / baseline_values
    out = out.drop(columns=["_relative_baseline"])
    return out


def _axis_label(axis: str | None, options: SuiteBarPlotOptions) -> str:
    if axis is None:
        return ""
    return str(options.axis_label_map.get(axis, axis))


def _mapped_value(axis: str | None, value: object, options: SuiteBarPlotOptions) -> str:
    if axis is None:
        return str(value)
    mapping = options.label_maps.get(axis, {})
    for key in (value, str(value)):
        try:
            if key in mapping:
                return str(mapping[key])
        except TypeError:
            continue
    return str(value)


def _stack_label(value: object, options: SuiteBarPlotOptions) -> str:
    if "stack_key" in options.label_maps:
        return _mapped_value("stack_key", value, options)
    return _mapped_value(options.stack_by, value, options)


def _subplot_title(
    row: str | None,
    row_value: object,
    col: str | None,
    col_value: object,
    options: SuiteBarPlotOptions,
) -> str:
    parts = []
    if row:
        parts.append(f"{_axis_label(row, options)}={_mapped_value(row, row_value, options)}")
    if col:
        parts.append(f"{_axis_label(col, options)}={_mapped_value(col, col_value, options)}")
    default = ", ".join(parts) if parts else "total"
    if not options.subplot_title_template:
        return default
    return options.subplot_title_template.format(
        parts=default,
        row_axis=row or "",
        row_axis_label=_axis_label(row, options),
        row_value="" if row is None else row_value,
        row_value_label="" if row is None else _mapped_value(row, row_value, options),
        col_axis=col or "",
        col_axis_label=_axis_label(col, options),
        col_value="" if col is None else col_value,
        col_value_label="" if col is None else _mapped_value(col, col_value, options),
    )


def _axis_filter(rows: pd.DataFrame, axis: str | None, value: object) -> pd.Series:
    if axis is None:
        return pd.Series(True, index=rows.index)
    if isinstance(value, float) and math.isnan(value):
        return rows[axis].isna()
    return rows[axis] == value


def _label_offset(max_height: float) -> float:
    return max(float(max_height), 1.0) * 0.01


def _label_bar(
    ax,
    xpos: float,
    height: float,
    text: str,
    max_height: float,
    *,
    rotation: int = 0,
    level: int = 1,
) -> None:
    ax.text(
        xpos,
        height + _label_offset(max_height) * max(1, level),
        text,
        ha="center",
        va="bottom",
        rotation=rotation,
        fontsize=7,
    )


def _set_bar_ylim(ax, max_height: float) -> None:
    top = max(float(max_height), 1.0) * 1.14
    ax.set_ylim(0.0, top)


def _format_value_label(value: float, relative: bool) -> str:
    return f"{value:.2f}x" if relative else f"{value:.1f}"


def _bar_ylabel(options: SuiteBarPlotOptions) -> str:
    if options.y_label is not None:
        return options.y_label
    return "relative latency (best = 1.0)" if options.relative else f"weighted total {options.metric} (us)"


def _stack_color(stack_idx: int, hue_idx: int, stack_count: int, options: SuiteBarPlotOptions):
    if options.stack_legend_scope != "hue":
        return BLUE_GREEN_PALETTE[stack_idx % len(BLUE_GREEN_PALETTE)]
    cmap = plt.get_cmap(HUE_STACK_CMAPS[hue_idx % len(HUE_STACK_CMAPS)])
    if stack_count <= 1:
        value = 0.68
    else:
        value = 0.32 + 0.58 * (stack_idx / max(stack_count - 1, 1))
    return cmap(value)


def _legend_ncol(count: int, options: SuiteBarPlotOptions) -> int:
    return options.legend_ncol or min(max(count, 1), 4)


def _nonzero_bar_segments(
    positions: list[float],
    heights: list[float],
    bottoms: list[float],
) -> list[tuple[float, float, float]]:
    return [
        (position, height, bottom)
        for position, height, bottom in zip(positions, heights, bottoms)
        if height > 0.0
    ]


def _add_hue_stack_legends(
    fig,
    hue_values: list[object],
    hue: str,
    legend_groups: dict[object, dict[str, Patch]],
    options: SuiteBarPlotOptions,
) -> None:
    active_groups = [
        (hue_value, legend_groups[hue_value])
        for hue_value in hue_values
        if legend_groups.get(hue_value)
    ]
    if not active_groups:
        return

    top = 0.94 if options.figure_title else 1.0
    if options.legend_position == "right":
        fig.tight_layout(rect=(0, 0, 0.76, top))
        legend_ax = fig.add_axes([0.78, 0.04, 0.20, max(0.01, top - 0.06)])
        legend_ax.set_axis_off()
        ncol = options.legend_ncol or 1
        group_rows = [
            (hue_value, by_label, math.ceil(len(by_label) / ncol))
            for hue_value, by_label in active_groups
        ]
        total_lines = sum(1 + rows + 1 for _, _, rows in group_rows)
        line_step = min(0.045, 0.96 / max(total_lines, 1))
        fontsize = max(4.5, min(8.0, line_step * fig.get_figheight() * 72.0 * 0.72))
        y = 0.98
        for hue_value, by_label, rows in group_rows:
            legend_ax.text(
                0.0,
                y,
                f"{_axis_label(hue, options)}={_mapped_value(hue, hue_value, options)}",
                transform=legend_ax.transAxes,
                ha="left",
                va="top",
                fontsize=fontsize,
                fontweight="bold",
            )
            y -= line_step
            labels = list(by_label.keys())
            handles = list(by_label.values())
            col_width = 1.0 / max(ncol, 1)
            for item_idx, (label, handle) in enumerate(zip(labels, handles)):
                row_idx = item_idx % rows
                col_idx = item_idx // rows
                item_y = y - row_idx * line_step
                item_x = col_idx * col_width
                legend_ax.add_patch(Rectangle(
                    (item_x, item_y - line_step * 0.62),
                    min(0.045, col_width * 0.20),
                    line_step * 0.42,
                    transform=legend_ax.transAxes,
                    facecolor=handle.get_facecolor(),
                    edgecolor="none",
                ))
                legend_ax.text(
                    item_x + min(0.065, col_width * 0.28),
                    item_y,
                    label,
                    transform=legend_ax.transAxes,
                    ha="left",
                    va="top",
                    fontsize=fontsize,
                )
            y -= rows * line_step + line_step * 0.65
    elif options.legend_position == "bottom":
        fig.tight_layout(rect=(0, 0.18, 1, top))
        step = 1.0 / max(len(active_groups), 1)
        for idx, (hue_value, by_label) in enumerate(active_groups):
            x = (idx + 0.5) * step
            fig.legend(
                by_label.values(),
                by_label.keys(),
                title=f"{_axis_label(hue, options)}={_mapped_value(hue, hue_value, options)}",
                loc="lower center",
                bbox_to_anchor=(x, 0.02),
                ncol=_legend_ncol(len(by_label), options),
                frameon=False,
            )
    else:
        fig.tight_layout(rect=(0, 0, 1, 0.82 if options.figure_title else 0.86))
        step = 1.0 / max(len(active_groups), 1)
        for idx, (hue_value, by_label) in enumerate(active_groups):
            x = (idx + 0.5) * step
            fig.legend(
                by_label.values(),
                by_label.keys(),
                title=f"{_axis_label(hue, options)}={_mapped_value(hue, hue_value, options)}",
                loc="upper center",
                bbox_to_anchor=(x, 0.98),
                ncol=_legend_ncol(len(by_label), options),
                frameon=False,
            )


def plot_suite_bar_grid(plot_data: pd.DataFrame, stack_data: pd.DataFrame, options: SuiteBarPlotOptions) -> None:
    if plot_data.empty:
        raise ValueError("no plot data to visualize")

    x, hue, row, col = _validate_bar_axes(options)
    _validate_bar_options(options)
    active_axes = tuple(axis for axis in (x, hue, row, col) if axis is not None)
    rows = _aggregate_for_axes(plot_data, active_axes)
    value_col = "plot_value"
    rows[value_col] = rows["total_latency_us"]
    relative_group_axes = _relative_group_axes(options.relative_scope, x, row, col)
    baselines = _relative_baselines(rows, value_col, relative_group_axes)
    if options.relative:
        rows = _apply_relative_values(rows, value_col, baselines, relative_group_axes)

    if hue is None:
        hue_key = "__series__"
        rows[hue_key] = "total"
    else:
        hue_key = hue

    row_values = _ordered_values(rows[row], axis=row, options=options) if row else [None]
    col_values = _ordered_values(rows[col], axis=col, options=options) if col else [None]
    x_values = _ordered_values(rows[x], axis=x, options=options)
    hue_values = _ordered_values(rows[hue_key], axis=hue, options=options)
    stack_rows = pd.DataFrame()
    stack_values: list[object] = []
    if options.stacked:
        stack_rows = _aggregate_stack_for_axes(stack_data, active_axes)
        stack_rows[value_col] = stack_rows["total_latency_us"]
        if options.relative:
            stack_rows = _apply_relative_values(stack_rows, value_col, baselines, relative_group_axes)
        if hue is None:
            stack_rows[hue_key] = "total"
        stack_values = _ordered_values(stack_rows["stack_key"], axis="stack_key", options=options)

    nrows = len(row_values)
    ncols = len(col_values)
    fig_width = max(7.0, min(22.0, 2.6 * len(x_values) + 1.8 * len(hue_values) + 2.0 * ncols))
    fig_height = max(4.5, 3.8 * nrows)
    fig, axes = plt.subplots(
        nrows,
        ncols,
        figsize=(fig_width, fig_height),
        squeeze=False,
        sharey=options.share_y,
    )
    if options.figure_title:
        fig.suptitle(options.figure_title)

    bar_width = min(0.8 / max(1, len(hue_values)), 0.28)
    x_positions = list(range(len(x_values)))
    global_max_height = max(float(rows[value_col].max()), 1.0)
    hue_scoped_stack_legend = options.stacked and options.stack_legend_scope == "hue" and hue is not None
    hue_legend_groups: dict[object, dict[str, Patch]] = {}

    for row_idx, row_value in enumerate(row_values):
        for col_idx, col_value in enumerate(col_values):
            ax = axes[row_idx][col_idx]
            scoped = rows[_axis_filter(rows, row, row_value) & _axis_filter(rows, col, col_value)]
            local_max_height = max(float(scoped[value_col].max()) if not scoped.empty else 0.0, 1.0)
            label_max_height = global_max_height if options.share_y else local_max_height
            if options.stacked:
                for hue_idx, hue_value in enumerate(hue_values):
                    offset = (hue_idx - (len(hue_values) - 1) / 2.0) * bar_width
                    positions = [pos + offset for pos in x_positions]
                    total_sub = scoped[_axis_filter(scoped, hue_key, hue_value)]
                    total_by_x = {item[x]: item for _, item in total_sub.iterrows()}
                    scoped_stack = stack_rows[
                        _axis_filter(stack_rows, row, row_value)
                        & _axis_filter(stack_rows, col, col_value)
                        & _axis_filter(stack_rows, hue_key, hue_value)
                    ]
                    bottoms = [0.0] * len(x_values)
                    for stack_idx, stack_value in enumerate(stack_values):
                        sub = scoped_stack[_axis_filter(scoped_stack, "stack_key", stack_value)]
                        by_x = {item[x]: item for _, item in sub.iterrows()}
                        heights = [float(by_x.get(x_value, {}).get(value_col, 0.0)) for x_value in x_values]
                        drawable = _nonzero_bar_segments(positions, heights, bottoms)
                        if not drawable:
                            continue
                        stack_label = _stack_label(stack_value, options)
                        color = _stack_color(stack_idx, hue_idx, len(stack_values), options)
                        if hue_scoped_stack_legend:
                            hue_legend_groups.setdefault(hue_value, {}).setdefault(
                                stack_label,
                                Patch(facecolor=color, edgecolor="black", label=stack_label),
                            )
                        draw_positions, draw_heights, draw_bottoms = zip(*drawable)
                        ax.bar(
                            draw_positions,
                            draw_heights,
                            width=bar_width,
                            bottom=draw_bottoms,
                            label="_nolegend_" if hue_scoped_stack_legend else stack_label,
                            color=color,
                            edgecolor="black",
                            linewidth=0.35,
                        )
                        bottoms = [base + value for base, value in zip(bottoms, heights)]

                    for xpos, x_value, total in zip(positions, x_values, bottoms):
                        missing_count = int(total_by_x.get(x_value, {}).get("missing_case_count", 0))
                        bar_total = float(total_by_x.get(x_value, {}).get(value_col, total))
                        if options.value_labels:
                            _label_bar(
                                ax,
                                xpos,
                                bar_total,
                                _format_value_label(bar_total, options.relative),
                                label_max_height,
                            )
                        if missing_count:
                            _label_bar(
                                ax,
                                xpos,
                                bar_total,
                                f"missing {missing_count}",
                                label_max_height,
                                rotation=90,
                                level=2 if options.value_labels else 1,
                            )
            else:
                for hue_idx, hue_value in enumerate(hue_values):
                    sub = scoped[_axis_filter(scoped, hue_key, hue_value)]
                    by_x = {item[x]: item for _, item in sub.iterrows()}
                    heights = [float(by_x.get(x_value, {}).get(value_col, 0.0)) for x_value in x_values]
                    missing = [int(by_x.get(x_value, {}).get("missing_case_count", 0)) for x_value in x_values]
                    offset = (hue_idx - (len(hue_values) - 1) / 2.0) * bar_width
                    positions = [pos + offset for pos in x_positions]
                    ax.bar(
                        positions,
                        heights,
                        width=bar_width,
                        label=_mapped_value(hue, hue_value, options),
                        color=BLUE_GREEN_PALETTE[hue_idx % len(BLUE_GREEN_PALETTE)],
                        edgecolor="black",
                        linewidth=0.5,
                    )
                    for xpos, height, missing_count in zip(positions, heights, missing):
                        if options.value_labels:
                            _label_bar(
                                ax,
                                xpos,
                                height,
                                _format_value_label(height, options.relative),
                                label_max_height,
                            )
                        if missing_count:
                            _label_bar(
                                ax,
                                xpos,
                                height,
                                f"missing {missing_count}",
                                label_max_height,
                                rotation=90,
                                level=2 if options.value_labels else 1,
                            )

            ax.set_title(_subplot_title(row, row_value, col, col_value, options))
            if options.stacked and hue is not None and len(hue_values) > 1:
                tick_positions = []
                tick_labels = []
                for pos, x_value in zip(x_positions, x_values):
                    for hue_idx, hue_value in enumerate(hue_values):
                        offset = (hue_idx - (len(hue_values) - 1) / 2.0) * bar_width
                        tick_positions.append(pos + offset)
                        tick_labels.append(
                            f"{_mapped_value(x, x_value, options)}\n{_mapped_value(hue, hue_value, options)}"
                        )
                ax.set_xticks(tick_positions)
                ax.set_xticklabels(tick_labels, rotation=25, ha="right")
            else:
                ax.set_xticks(x_positions)
                ax.set_xticklabels([_mapped_value(x, value, options) for value in x_values], rotation=25, ha="right")
            ax.set_xlabel(options.x_label if options.x_label is not None else _axis_label(x, options))
            ax.set_ylabel(_bar_ylabel(options))
            ax.set_axisbelow(True)
            ax.grid(axis="y", alpha=0.25, zorder=0)
            if not options.share_y:
                _set_bar_ylim(ax, local_max_height)

    if options.share_y:
        for ax in axes.flat:
            _set_bar_ylim(ax, global_max_height)

    legend_drawn = False
    if hue_scoped_stack_legend and options.legend_position != "none" and hue_legend_groups:
        _add_hue_stack_legends(fig, hue_values, hue, hue_legend_groups, options)
        legend_drawn = True
    else:
        handles, labels = axes[0][0].get_legend_handles_labels()
    if not hue_scoped_stack_legend and handles and options.legend_position != "none":
        by_label = dict(zip(labels, handles))
        legend_title = options.legend_title
        if legend_title is None:
            legend_title = _axis_label(options.stack_by if options.stacked else hue, options)
        if options.legend_position == "right":
            fig.tight_layout(rect=(0, 0, 0.78, 0.94 if options.figure_title else 1))
            fig.legend(
                by_label.values(),
                by_label.keys(),
                title=legend_title,
                loc="center left",
                bbox_to_anchor=(0.80, 0.5),
                ncol=options.legend_ncol or 1,
                frameon=False,
            )
        elif options.legend_position == "bottom":
            ncol = options.legend_ncol or min(len(by_label), 4)
            fig.tight_layout(rect=(0, 0.12, 1, 0.94 if options.figure_title else 1))
            fig.legend(
                by_label.values(),
                by_label.keys(),
                title=legend_title,
                loc="upper center",
                bbox_to_anchor=(0.5, 0.06),
                ncol=ncol,
                frameon=False,
            )
        else:
            ncol = options.legend_ncol or min(len(by_label), 4)
            fig.tight_layout(rect=(0, 0, 1, 0.88 if options.figure_title else 0.92))
            fig.legend(
                by_label.values(),
                by_label.keys(),
                title=legend_title,
                loc="upper center",
                bbox_to_anchor=(0.5, 0.98),
                ncol=ncol,
                frameon=False,
            )
        legend_drawn = True
    if not legend_drawn:
        fig.tight_layout(rect=(0, 0, 1, 0.94 if options.figure_title else 1))

    options.out_dir.mkdir(parents=True, exist_ok=True)
    name = f"bar_total_{options.metric}"
    fig.savefig(options.out_dir / f"{name}.png", dpi=180, bbox_inches="tight")
    fig.savefig(options.out_dir / f"{name}.pdf", bbox_inches="tight")
    plt.close(fig)


def visualize_suites(suites: list[BenchSuite], options: SuiteBarPlotOptions) -> None:
    unscaled, scaled = prepare_suite_bar_data_versions(suites, options)
    write_suite_bar_data_csvs(unscaled, options.out_dir)
    plot_input = scaled or unscaled
    if scaled is not None:
        write_suite_bar_data_csvs(scaled, options.out_dir, suffix="_scaled")
    plot_suite_bar_grid(plot_input.plot_data, plot_input.stack_data, options)
    print(f"wrote suite bar figures to {options.out_dir}")
