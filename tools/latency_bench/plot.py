from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from .compose import ComposeOptions, compose_latency, normalize_args
from .suite import BenchCase, BenchDefaults, BenchSuite


BAR_AXIS_COLUMNS = ("stage", "seq_len", "batch", "variant")
BAR_AXIS_CHOICES = (*BAR_AXIS_COLUMNS, "none")
STACK_BY_COLUMNS = ("name", "case_id", "kind", "backend", "op", "app")
DEFAULT_BAR_X = "seq_len"
DEFAULT_BAR_HUE = "variant"
DEFAULT_BAR_ROW = "stage"
DEFAULT_BAR_COL = "batch"
DEFAULT_STACK_BY = "name"
_NONE_AXIS = "none"
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
    share_y: bool = False
    fpga_bin_label: str | None = None
    xclbin_sha256: str | None = None


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


def _combine_suites(suites: list[BenchSuite]) -> tuple[BenchSuite, dict[str, str]]:
    if not suites:
        raise ValueError("at least one suite is required")

    cases: list[BenchCase] = []
    seen: set[tuple[object, ...]] = set()
    source_suites: dict[str, list[str]] = {}
    for suite in suites:
        for case in suite.cases:
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
    for key in ("seq_len", "seq", "prefill_seq_len", "gen_kv_len"):
        found = _int_or_none(shape.get(key))
        if found is not None:
            return found
    case_id = row.get("case_id", "")
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
    combined_suite, source_suites = _combine_suites(suites)
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
        ),
    )
    composed = _add_bar_axis_columns(composed, source_suites)
    composed["weighted_latency_us"] = pd.to_numeric(composed["weighted_latency_us"], errors="coerce")
    composed["_weighted_latency_filled"] = composed["weighted_latency_us"].fillna(0.0)
    composed["stack_key"] = composed.apply(lambda row: _stack_key(row, options.stack_by), axis=1)

    plot_data = (
        composed.groupby(list(BAR_AXIS_COLUMNS), dropna=False, as_index=False, sort=True)
        .agg(
            total_latency_us=("_weighted_latency_filled", "sum"),
            case_count=("case_id", "count"),
            pass_case_count=("compose_status", lambda values: int((values.astype(str) == "pass").sum())),
            missing_case_count=("compose_status", lambda values: int((values.astype(str) != "pass").sum())),
            source_suites=("source_suites", lambda values: _unique_join(values.astype(str))),
            source_raw_dbs=("source_raw_dbs", lambda values: _unique_join(values.astype(str))),
        )
    )
    plot_data.insert(0, "metric", options.metric)

    stack_data = (
        composed.groupby([*BAR_AXIS_COLUMNS, "stack_key"], dropna=False, as_index=False, sort=True)
        .agg(
            total_latency_us=("_weighted_latency_filled", "sum"),
            case_count=("case_id", "count"),
            pass_case_count=("compose_status", lambda values: int((values.astype(str) == "pass").sum())),
            missing_case_count=("compose_status", lambda values: int((values.astype(str) != "pass").sum())),
            source_cases=("case_id", lambda values: _unique_join(values.astype(str))),
            source_suites=("source_suites", lambda values: _unique_join(values.astype(str))),
            source_raw_dbs=("source_raw_dbs", lambda values: _unique_join(values.astype(str))),
        )
    )
    stack_data.insert(0, "metric", options.metric)
    return composed.drop(columns=["_weighted_latency_filled"]), plot_data, stack_data


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


def _sort_key(value: object) -> tuple[int, float | str]:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return (2, "")
    try:
        return (0, float(str(value)))
    except ValueError:
        return (1, str(value))


def _ordered_values(series: pd.Series) -> list[object]:
    values = series.drop_duplicates().tolist()
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


def _relative_baseline(rows: pd.DataFrame, value_col: str) -> float:
    values = pd.to_numeric(rows[value_col], errors="coerce").fillna(0.0)
    positive = values[values > 0]
    return float(positive.min()) if not positive.empty else 1.0


def _apply_relative_values(rows: pd.DataFrame, value_col: str, baseline: float) -> pd.DataFrame:
    out = rows.copy()
    values = pd.to_numeric(out[value_col], errors="coerce").fillna(0.0)
    out[value_col] = values / baseline
    return out


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
    return "relative latency (best = 1.0)" if options.relative else f"weighted total {options.metric} (us)"


def plot_suite_bar_grid(plot_data: pd.DataFrame, stack_data: pd.DataFrame, options: SuiteBarPlotOptions) -> None:
    if plot_data.empty:
        raise ValueError("no plot data to visualize")

    x, hue, row, col = _validate_bar_axes(options)
    active_axes = tuple(axis for axis in (x, hue, row, col) if axis is not None)
    rows = _aggregate_for_axes(plot_data, active_axes)
    value_col = "plot_value"
    rows[value_col] = rows["total_latency_us"]
    baseline = _relative_baseline(rows, value_col)
    if options.relative:
        rows = _apply_relative_values(rows, value_col, baseline)

    if hue is None:
        hue_key = "__series__"
        rows[hue_key] = "total"
    else:
        hue_key = hue

    row_values = _ordered_values(rows[row]) if row else [None]
    col_values = _ordered_values(rows[col]) if col else [None]
    x_values = _ordered_values(rows[x])
    hue_values = _ordered_values(rows[hue_key])
    stack_rows = pd.DataFrame()
    stack_values: list[object] = []
    if options.stacked:
        stack_rows = _aggregate_stack_for_axes(stack_data, active_axes)
        stack_rows[value_col] = stack_rows["total_latency_us"]
        if options.relative:
            stack_rows = _apply_relative_values(stack_rows, value_col, baseline)
        if hue is None:
            stack_rows[hue_key] = "total"
        stack_values = _ordered_values(stack_rows["stack_key"])

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

    colors = BLUE_GREEN_PALETTE
    bar_width = min(0.8 / max(1, len(hue_values)), 0.28)
    x_positions = list(range(len(x_values)))
    global_max_height = max(float(rows[value_col].max()), 1.0)

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
                        ax.bar(
                            positions,
                            heights,
                            width=bar_width,
                            bottom=bottoms,
                            label=str(stack_value),
                            color=colors[stack_idx % len(colors)],
                            edgecolor="white",
                            linewidth=0.5,
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
                        label=str(hue_value),
                        color=colors[hue_idx % len(colors)],
                        edgecolor="white",
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

            title_parts = []
            if row:
                title_parts.append(f"{row}={row_value}")
            if col:
                title_parts.append(f"{col}={col_value}")
            ax.set_title(", ".join(title_parts) if title_parts else "total")
            if options.stacked and hue is not None and len(hue_values) > 1:
                tick_positions = []
                tick_labels = []
                for pos, x_value in zip(x_positions, x_values):
                    for hue_idx, hue_value in enumerate(hue_values):
                        offset = (hue_idx - (len(hue_values) - 1) / 2.0) * bar_width
                        tick_positions.append(pos + offset)
                        tick_labels.append(f"{x_value}\n{hue_value}")
                ax.set_xticks(tick_positions)
                ax.set_xticklabels(tick_labels, rotation=25, ha="right")
            else:
                ax.set_xticks(x_positions)
                ax.set_xticklabels([str(value) for value in x_values], rotation=25, ha="right")
            ax.set_xlabel(x)
            ax.set_ylabel(_bar_ylabel(options))
            ax.grid(axis="y", alpha=0.25)
            if not options.share_y:
                _set_bar_ylim(ax, local_max_height)

    if options.share_y:
        for ax in axes.flat:
            _set_bar_ylim(ax, global_max_height)

    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        by_label = dict(zip(labels, handles))
        legend_title = options.stack_by if options.stacked else hue
        fig.legend(
            by_label.values(),
            by_label.keys(),
            title=legend_title,
            loc="upper center",
            ncol=min(len(by_label), 4),
            frameon=False,
        )
        fig.tight_layout(rect=(0, 0, 1, 0.92))
    else:
        fig.tight_layout()

    options.out_dir.mkdir(parents=True, exist_ok=True)
    name = f"bar_total_{options.metric}"
    fig.savefig(options.out_dir / f"{name}.png", dpi=180, bbox_inches="tight")
    fig.savefig(options.out_dir / f"{name}.pdf", bbox_inches="tight")
    plt.close(fig)


def visualize_suites(suites: list[BenchSuite], options: SuiteBarPlotOptions) -> None:
    composed, plot_data, stack_data = prepare_suite_bar_data(suites, options)
    options.out_dir.mkdir(parents=True, exist_ok=True)
    composed.to_csv(options.out_dir / "composed_cases.csv", index=False)
    plot_data.to_csv(options.out_dir / "plot_data.csv", index=False)
    stack_data.to_csv(options.out_dir / "plot_stack_data.csv", index=False)
    plot_suite_bar_grid(plot_data, stack_data, options)
    print(f"wrote suite bar figures to {options.out_dir}")
