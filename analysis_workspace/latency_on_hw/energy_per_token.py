from __future__ import annotations

import csv
import json
import math
import re
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.latency_bench.fpga_bins import resolve_fpga_bin_config  # noqa: E402

PREFILL_STAGE = "prefill"
GENERATION_STAGE = "generation"
DEFAULT_STAGE_ORDER = (PREFILL_STAGE, GENERATION_STAGE)
SHARE_Y_SCOPE_CHOICES = ("none", "global", "row")
FIGURE_TITLE_LAYOUT_TOP = 0.97
DEFAULT_POWER_METRIC = "power_avg_W"
DEFAULT_FPGA_PERIOD_S = 10e-9
POWER_METRIC_COLUMN_ALIASES = {
    "power_avg_W": ("power_avg_W", "power_avg_w"),
    "power_vcc_avg_W": ("power_vcc_avg_W", "power_vcc_avg_w"),
    "power_dynamic_avg_W": ("power_dynamic_avg_W", "power_dynamic_avg_w"),
}
XCLBIN_INFO_FILENAMES = ("vortex_xclbin.info", "vortex_afu.xclbin.info")
POWER_SUMMARY_FIELDS = (
    "power_metric",
    "stage",
    "batch",
    "seq_len",
    "variant",
    "tokens",
    "total_energy_j",
    "joules_per_token",
    "relative_joules_per_token",
    "relative_baseline_joules_per_token",
    "relative_scope",
    "component_count",
    "energy_component_count",
    "measured_power_count",
    "imputed_power_count",
    "missing_power_count",
    "missing_cycle_count",
    "missing_latency_count",
    "complete",
)


@dataclass(frozen=True)
class PowerCandidate:
    row: Mapping[str, Any]
    fpga_bin_label: str
    app: str
    args: str
    stage: str
    shape: dict[str, Any]
    numeric_shape: dict[str, float]
    categorical_shape: dict[str, str]
    power_values_W: dict[str, float]
    power_samples: int
    fpga_cycle_avg: float | None


@dataclass(frozen=True)
class PowerResolution:
    candidate: PowerCandidate | None
    resolution: str
    scope: str
    distance: float | None


@dataclass(frozen=True)
class EnergyPlotResult:
    rows: Any
    summary: Any
    rows_csv: Path
    summary_csv: Path
    figure_path: Path
    figure_svg_path: Path | None = None


class PowerResolver:
    def __init__(self, candidates: Iterable[PowerCandidate]) -> None:
        self._candidates = list(candidates)
        self._by_exact: dict[tuple[str, str, str], list[PowerCandidate]] = {}
        self._by_fpga_app: dict[tuple[str, str], list[PowerCandidate]] = {}
        self._by_app: dict[str, list[PowerCandidate]] = {}
        for candidate in self._candidates:
            self._by_exact.setdefault(
                (candidate.fpga_bin_label, candidate.app, candidate.args),
                [],
            ).append(candidate)
            self._by_fpga_app.setdefault(
                (candidate.fpga_bin_label, candidate.app),
                [],
            ).append(candidate)
            self._by_app.setdefault(candidate.app, []).append(candidate)

    @property
    def candidates(self) -> list[PowerCandidate]:
        return list(self._candidates)

    def resolve(self, row: Mapping[str, Any]) -> PowerResolution:
        fpga_bin_label = _target_fpga_bin_label(row)
        app = _text(row.get("app"))
        args = _text(row.get("args"))
        exact = self._by_exact.get((fpga_bin_label, app, args), ())
        if exact:
            return PowerResolution(
                candidate=_best_exact_candidate(exact),
                resolution="measured",
                scope="exact",
                distance=0.0,
            )

        target_shape = _shape_for_row(row)
        target_numeric, target_categorical = _split_shape(target_shape)
        target_stage = _stage(row)
        scoped_candidates = self._by_fpga_app.get((fpga_bin_label, app), ())
        scope = "same_fpga_app"
        if not scoped_candidates:
            scoped_candidates = self._by_app.get(app, ())
            scope = "same_app"
        if not scoped_candidates:
            return PowerResolution(
                candidate=None,
                resolution="missing",
                scope="none",
                distance=None,
            )

        best_distance = math.inf
        best_candidate: PowerCandidate | None = None
        for candidate in scoped_candidates:
            distance = _shape_distance(
                target_numeric=target_numeric,
                target_categorical=target_categorical,
                target_stage=target_stage,
                candidate=candidate,
            )
            if _candidate_rank(distance, target_stage, candidate) < _candidate_rank(
                best_distance,
                target_stage,
                best_candidate,
            ):
                best_distance = distance
                best_candidate = candidate

        return PowerResolution(
            candidate=best_candidate,
            resolution="imputed" if best_candidate is not None else "missing",
            scope=scope if best_candidate is not None else "none",
            distance=best_distance if best_candidate is not None else None,
        )


def read_power_records(raw_dbs: Sequence[str | Path]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for raw_db in raw_dbs:
        path = Path(raw_db)
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            rows.extend(dict(row) for row in reader)
    return rows


def build_power_resolver(
    raw_dbs: Sequence[str | Path],
    *,
    power_metric: str = DEFAULT_POWER_METRIC,
) -> PowerResolver:
    return PowerResolver(
        _power_candidates(
            read_power_records(raw_dbs),
            required_power_metric=_canonical_power_metric(power_metric),
        )
    )


def energy_rows_from_records(
    composed_records: Iterable[Mapping[str, Any]],
    raw_dbs: Sequence[str | Path],
    *,
    idle_power_w: float = 0.0,
    include_idle_power: bool = False,
    power_metric: str = DEFAULT_POWER_METRIC,
    fpga_period_s: float = DEFAULT_FPGA_PERIOD_S,
    allow_generic_power_estimate: bool = True,
) -> list[dict[str, Any]]:
    canonical_power_metric = _canonical_power_metric(power_metric)
    resolver = build_power_resolver(raw_dbs, power_metric=canonical_power_metric)
    rows: list[dict[str, Any]] = []
    for row in composed_records:
        rows.append(
            energy_row_from_record(
                row,
                resolver=resolver,
                idle_power_w=idle_power_w,
                include_idle_power=include_idle_power,
                power_metric=canonical_power_metric,
                fpga_period_s=fpga_period_s,
                allow_generic_power_estimate=allow_generic_power_estimate,
            )
        )
    return rows


def energy_row_from_record(
    row: Mapping[str, Any],
    *,
    resolver: PowerResolver,
    idle_power_w: float = 0.0,
    include_idle_power: bool = False,
    power_metric: str = DEFAULT_POWER_METRIC,
    fpga_period_s: float = DEFAULT_FPGA_PERIOD_S,
    allow_generic_power_estimate: bool = True,
) -> dict[str, Any]:
    canonical_power_metric = _canonical_power_metric(power_metric)
    composed_power = _power_value(row, canonical_power_metric)
    if composed_power is not None:
        resolution = PowerResolution(
            candidate=None,
            resolution=_text(row.get("power_resolution_kind")) or "measured",
            scope="composed",
            distance=_to_float(row.get("power_interpolation_upper_ratio")),
        )
    elif allow_generic_power_estimate:
        resolution = resolver.resolve(row)
    else:
        resolution = PowerResolution(
            candidate=None,
            resolution="missing",
            scope="none",
            distance=None,
        )
    candidate = resolution.candidate
    exact_candidate = candidate if resolution.scope == "exact" else None
    weighted_fpga_cycles = _weighted_fpga_cycles(row, exact_candidate)
    resolved_fpga_period_s = _fpga_period_s(row, candidate, default=fpga_period_s)
    tokens = _token_count(row)

    raw_power_W: float | None = None
    effective_power_W: float | None = None
    if composed_power is not None:
        raw_power_W = composed_power
        effective_power_W = composed_power
    elif candidate is not None:
        raw_power_W = candidate.power_values_W.get(canonical_power_metric)
        effective_power_W = raw_power_W

    energy_time_s: float | None = None
    kernel_energy_j: float | None = None
    joules_per_token_component: float | None = None
    if weighted_fpga_cycles is not None and resolved_fpga_period_s is not None:
        energy_time_s = weighted_fpga_cycles * resolved_fpga_period_s
    if energy_time_s is not None and effective_power_W is not None:
        kernel_energy_j = energy_time_s * effective_power_W
        if tokens and tokens > 0:
            joules_per_token_component = kernel_energy_j / tokens

    output = dict(row)
    output.update(
        {
            "power_metric": canonical_power_metric,
            "energy_stage": _stage(row),
            "energy_batch": _batch(row),
            "energy_seq_len": _seq_len(row),
            "energy_tokens": tokens,
            "power_resolution": resolution.resolution,
            "power_match_scope": resolution.scope,
            "power_distance": resolution.distance,
            "power_source_case_id": candidate.row.get("case_id", "") if candidate else "",
            "power_source_fpga_bin_label": candidate.fpga_bin_label if candidate else "",
            "power_source_app": candidate.app if candidate else "",
            "power_source_args": candidate.args if candidate else "",
            "power_source_shape_json": candidate.row.get("shape_json", "") if candidate else "",
            "power_source_samples": candidate.power_samples if candidate else "",
            "raw_power_W": raw_power_W,
            "raw_power_w": raw_power_W,
            "idle_power_w": idle_power_w,
            "include_idle_power": include_idle_power,
            "effective_power_W": effective_power_W,
            "effective_power_w": effective_power_W,
            "fpga_cycle_avg": _fpga_cycle_avg(row, exact_candidate),
            "energy_weighted_fpga_cycles": weighted_fpga_cycles,
            "fpga_period_s": resolved_fpga_period_s,
            "energy_time_s": energy_time_s,
            "kernel_energy_j": kernel_energy_j,
            "joules_per_token_component": joules_per_token_component,
            "energy_missing_cycle": weighted_fpga_cycles is None,
            "energy_missing_latency": weighted_fpga_cycles is None,
            "energy_missing_power": raw_power_W is None,
        }
    )
    return output


def summarize_energy_rows(
    rows: Iterable[Mapping[str, Any]],
    *,
    group_by: Sequence[str] = (),
) -> list[dict[str, Any]]:
    group_fields = tuple(group_by)
    if len(set(group_fields)) != len(group_fields):
        raise ValueError(f"group_by fields must be unique: {group_fields}")
    reserved_fields = {
        "power_metric",
        "stage",
        "batch",
        "seq_len",
        "variant",
        "tokens",
        "total_energy_j",
        "component_count",
        "energy_component_count",
        "measured_power_count",
        "imputed_power_count",
        "missing_power_count",
        "missing_cycle_count",
        "missing_latency_count",
        "complete",
        "joules_per_token",
    }
    collisions = reserved_fields.intersection(group_fields)
    if collisions:
        raise ValueError(f"group_by fields conflict with summary columns: {sorted(collisions)}")

    groups: dict[tuple[Any, ...], dict[str, Any]] = {}
    for row in rows:
        power_metric = _canonical_power_metric(row.get("power_metric") or DEFAULT_POWER_METRIC)
        stage = _text(row.get("energy_stage")) or _stage(row)
        batch = row.get("energy_batch")
        if batch in (None, ""):
            batch = _batch(row)
        seq_len = row.get("energy_seq_len")
        if seq_len in (None, ""):
            seq_len = _seq_len(row)
        variant = _text(row.get("variant"))
        group_values = tuple(_text(row.get(field)) for field in group_fields)
        key = (power_metric, stage, batch, seq_len, variant, *group_values)
        group = groups.setdefault(
            key,
            {
                "power_metric": power_metric,
                "stage": stage,
                "batch": batch,
                "seq_len": seq_len,
                "variant": variant,
                "tokens": row.get("energy_tokens") or _token_count(row),
                "total_energy_j": 0.0,
                "component_count": 0,
                "energy_component_count": 0,
                "measured_power_count": 0,
                "imputed_power_count": 0,
                "missing_power_count": 0,
                "missing_cycle_count": 0,
                "missing_latency_count": 0,
                **dict(zip(group_fields, group_values)),
            },
        )
        group["component_count"] += 1
        energy = _to_float(row.get("kernel_energy_j"))
        if energy is not None:
            group["total_energy_j"] += energy
            group["energy_component_count"] += 1
        missing_cycle = (
            row.get("energy_missing_cycle") is True
            or (
                "energy_weighted_fpga_cycles" in row
                and _to_float(row.get("energy_weighted_fpga_cycles")) is None
            )
            or (
                "energy_weighted_fpga_cycles" not in row
                and row.get("energy_missing_latency") is True
            )
        )
        if missing_cycle:
            group["missing_cycle_count"] += 1
            group["missing_latency_count"] += 1
        resolution = _text(row.get("power_resolution"))
        if resolution == "measured":
            group["measured_power_count"] += 1
        elif resolution == "imputed":
            group["imputed_power_count"] += 1
        else:
            group["missing_power_count"] += 1

    summary = []
    for group in groups.values():
        tokens = _to_float(group.get("tokens"))
        complete = (
            group["missing_power_count"] == 0
            and group["missing_cycle_count"] == 0
            and tokens is not None
            and tokens > 0
        )
        group["complete"] = complete
        has_energy = group["energy_component_count"] > 0 and tokens is not None and tokens > 0
        group["joules_per_token"] = group["total_energy_j"] / tokens if has_energy else None
        summary.append(group)

    summary.sort(
        key=lambda row: (
            *_summary_sort_key(row),
            *(_text(row.get(field)) for field in group_fields),
        )
    )
    return summary


def write_energy_csvs(
    rows: Sequence[Mapping[str, Any]],
    summary: Sequence[Mapping[str, Any]],
    out_dir: str | Path,
) -> tuple[Path, Path]:
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    rows_csv = out_path / "energy_kernel_rows.csv"
    summary_csv = out_path / "energy_summary.csv"
    _write_dict_csv(rows_csv, rows)
    _write_dict_csv(summary_csv, summary, preferred_fields=POWER_SUMMARY_FIELDS)
    return rows_csv, summary_csv


def plot_energy_per_token(
    plot_result: Any,
    *,
    raw_dbs: Sequence[str | Path],
    out_dir: str | Path,
    idle_power_w: float,
    include_idle_power: bool = False,
    power_metric: str = DEFAULT_POWER_METRIC,
    fpga_period_s: float = DEFAULT_FPGA_PERIOD_S,
    title: str | None = None,
    label_maps: Mapping[str, Mapping[Any, str]] | None = None,
    value_orders: Mapping[str, Sequence[Any]] | None = None,
    palette: Sequence[str] | None = None,
    legend_title: str | None = "candidates",
    legend_position: str = "bottom",
    relative: bool = True,
    relative_scope: str = "x_tick",
    value_labels: bool = True,
    value_label_rotation: float = 90.0,
    value_label_fontsize: float = 7.0,
    grouped_bar_gap: float = 0.04,
    bar_edgecolor: str = "white",
    bar_linewidth: float = 0.25,
    bar_alpha: float = 1.0,
    x_tick_label_rotation: float = 0.0,
    x_tick_label_ha: str = "center",
    ylim_top_scale: float = 1.22,
    figure_size: tuple[float, float] | None = None,
    save_dpi: int = 180,
    title_fontsize: float = 13,
    subplot_title_fontsize: float = 10,
    axis_label_fontsize: float | None = None,
    tick_label_fontsize: float | None = None,
    legend_fontsize: float | None = None,
    legend_title_fontsize: float | None = None,
    share_y_scope: str = "none",
    subplot_wspace: float | None = None,
    subplot_hspace: float | None = None,
    shared_x_label: bool = False,
    shared_x_label_y: float | None = None,
    x_group_axis: str | None = None,
    x_group_gap: float = 1.2,
) -> EnergyPlotResult:
    pd, plt = _import_plotting_modules()
    records = _records_from_plot_result(plot_result)
    rows = energy_rows_from_records(
        records,
        raw_dbs,
        idle_power_w=idle_power_w,
        include_idle_power=include_idle_power,
        power_metric=power_metric,
        fpga_period_s=fpga_period_s,
    )
    summary = add_relative_energy_values(
        summarize_energy_rows(rows),
        relative_scope=relative_scope,
    )
    rows_csv, summary_csv = write_energy_csvs(rows, summary, out_dir)

    summary_df = pd.DataFrame(summary)
    rows_df = pd.DataFrame(rows)
    figure_path = Path(out_dir) / "energy_per_token.png"
    figure_svg_path = figure_path.with_suffix(".svg")
    _plot_summary_dataframe(
        summary_df,
        figure_path,
        title=title,
        label_maps=label_maps or {},
        value_orders=value_orders or {},
        palette=palette,
        legend_title=legend_title,
        legend_position=legend_position,
        include_idle_power=include_idle_power,
        relative=relative,
        value_labels=value_labels,
        value_label_rotation=value_label_rotation,
        value_label_fontsize=value_label_fontsize,
        grouped_bar_gap=grouped_bar_gap,
        bar_edgecolor=bar_edgecolor,
        bar_linewidth=bar_linewidth,
        bar_alpha=bar_alpha,
        x_tick_label_rotation=x_tick_label_rotation,
        x_tick_label_ha=x_tick_label_ha,
        ylim_top_scale=ylim_top_scale,
        figure_size=figure_size,
        save_dpi=save_dpi,
        title_fontsize=title_fontsize,
        subplot_title_fontsize=subplot_title_fontsize,
        axis_label_fontsize=axis_label_fontsize,
        tick_label_fontsize=tick_label_fontsize,
        legend_fontsize=legend_fontsize,
        legend_title_fontsize=legend_title_fontsize,
        share_y_scope=share_y_scope,
        subplot_wspace=subplot_wspace,
        subplot_hspace=subplot_hspace,
        shared_x_label=shared_x_label,
        shared_x_label_y=shared_x_label_y,
        x_group_axis=x_group_axis,
        x_group_gap=x_group_gap,
    )
    return EnergyPlotResult(
        rows=rows_df,
        summary=summary_df,
        rows_csv=rows_csv,
        summary_csv=summary_csv,
        figure_path=figure_path,
        figure_svg_path=figure_svg_path,
    )


def add_relative_energy_values(
    summary: Iterable[Mapping[str, Any]],
    *,
    relative_scope: str = "x_tick",
) -> list[dict[str, Any]]:
    rows = [dict(row) for row in summary]
    baselines: dict[tuple[Any, ...], float] = {}
    grouped_values: dict[tuple[Any, ...], list[float]] = {}
    for row in rows:
        value = _to_float(row.get("joules_per_token"))
        if value is None:
            continue
        grouped_values.setdefault(_relative_group_key(row, relative_scope), []).append(value)

    for key, values in grouped_values.items():
        baselines[key] = _series_relative_baseline(values)

    for row in rows:
        key = _relative_group_key(row, relative_scope)
        baseline = baselines.get(key, 1.0)
        value = _to_float(row.get("joules_per_token"))
        row["relative_baseline_joules_per_token"] = baseline
        row["relative_scope"] = relative_scope
        row["relative_joules_per_token"] = value / baseline if value is not None and baseline > 0 else None
    return rows


def add_relative_energy_component_values(
    component_summary: Iterable[Mapping[str, Any]],
    total_summary: Iterable[Mapping[str, Any]],
    *,
    relative_scope: str = "x_tick",
) -> list[dict[str, Any]]:
    totals = add_relative_energy_values(total_summary, relative_scope=relative_scope)
    baselines = {
        _relative_group_key(row, relative_scope): _to_float(
            row.get("relative_baseline_joules_per_token")
        )
        for row in totals
    }

    rows = [dict(row) for row in component_summary]
    for row in rows:
        baseline = baselines.get(_relative_group_key(row, relative_scope))
        value = _to_float(row.get("joules_per_token"))
        row["relative_baseline_joules_per_token"] = baseline
        row["relative_scope"] = relative_scope
        row["relative_joules_per_token"] = (
            value / baseline
            if value is not None and baseline is not None and baseline > 0
            else None
        )
    return rows


def _power_candidates(
    rows: Iterable[Mapping[str, Any]],
    *,
    required_power_metric: str | None = None,
) -> list[PowerCandidate]:
    candidates: list[PowerCandidate] = []
    required = _canonical_power_metric(required_power_metric) if required_power_metric else None
    for row in rows:
        power_samples = _to_int(row.get("power_samples"))
        if power_samples is None or power_samples <= 0:
            continue
        power_values_W = {
            metric: value
            for metric in POWER_METRIC_COLUMN_ALIASES
            if (value := _power_value(row, metric)) is not None
        }
        if required is not None:
            required_value = _power_value(row, required)
            if required_value is None:
                continue
            power_values_W[required] = required_value
        if not power_values_W:
            continue
        shape = _shape_for_row(row)
        numeric_shape, categorical_shape = _split_shape(shape)
        candidates.append(
            PowerCandidate(
                row=row,
                fpga_bin_label=_text(row.get("fpga_bin_label")),
                app=_text(row.get("app")),
                args=_text(row.get("args")),
                stage=_stage(row),
                shape=shape,
                numeric_shape=numeric_shape,
                categorical_shape=categorical_shape,
                power_values_W=power_values_W,
                power_samples=power_samples,
                fpga_cycle_avg=_to_float(row.get("fpga_cycle_avg")),
            )
        )
    return candidates


def _records_from_plot_result(plot_result: Any) -> list[Mapping[str, Any]]:
    composed = getattr(plot_result, "composed", plot_result)
    if hasattr(composed, "to_dict"):
        return list(composed.to_dict(orient="records"))
    return list(composed)


def _import_plotting_modules() -> tuple[Any, Any]:
    try:
        import matplotlib.pyplot as plt
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError(
            "plot_energy_per_token requires pandas and matplotlib; "
            "the CSV-only helpers can be used without those packages"
        ) from exc
    return pd, plt


def _plot_summary_dataframe(
    summary_df: Any,
    figure_path: Path,
    *,
    title: str | None,
    label_maps: Mapping[str, Mapping[Any, str]],
    value_orders: Mapping[str, Sequence[Any]],
    palette: Sequence[str] | None,
    legend_title: str | None,
    include_idle_power: bool,
    relative: bool,
    value_labels: bool,
    value_label_rotation: float,
    value_label_fontsize: float,
    grouped_bar_gap: float,
    bar_edgecolor: str,
    bar_linewidth: float,
    bar_alpha: float,
    x_tick_label_rotation: float,
    x_tick_label_ha: str,
    ylim_top_scale: float = 1.22,
    figure_size: tuple[float, float] | None = None,
    save_dpi: int = 180,
    title_fontsize: float = 13,
    subplot_title_fontsize: float = 10,
    axis_label_fontsize: float | None = None,
    tick_label_fontsize: float | None = None,
    legend_fontsize: float | None = None,
    legend_title_fontsize: float | None = None,
    legend_position: str = "bottom",
    share_y_scope: str = "none",
    subplot_wspace: float | None = None,
    subplot_hspace: float | None = None,
    shared_x_label: bool = False,
    shared_x_label_y: float | None = None,
    x_group_axis: str | None = None,
    x_group_gap: float = 1.2,
) -> None:
    _, plt = _import_plotting_modules()
    figure_path.parent.mkdir(parents=True, exist_ok=True)
    x_group_axis = _normalize_energy_x_group_axis(x_group_axis)
    _validate_energy_plot_layout_options(
        share_y_scope,
        subplot_wspace,
        subplot_hspace,
        x_group_axis,
        x_group_gap,
        shared_x_label_y,
    )
    if summary_df.empty:
        fig, ax = plt.subplots(figsize=(8, 3))
        ax.text(0.5, 0.5, "No energy rows", ha="center", va="center")
        ax.axis("off")
        fig.savefig(figure_path, bbox_inches="tight", dpi=160)
        fig.savefig(figure_path.with_suffix(".svg"), bbox_inches="tight")
        plt.close(fig)
        return

    value_col = "relative_joules_per_token" if relative else "joules_per_token"
    if value_col not in summary_df.columns:
        value_col = "joules_per_token"
    plottable = summary_df[summary_df[value_col].notna()].copy()
    if plottable.empty:
        fig, ax = plt.subplots(figsize=(9, 3))
        ax.text(0.5, 0.5, "No plottable energy rows", ha="center", va="center")
        ax.axis("off")
        fig.savefig(figure_path, bbox_inches="tight", dpi=160)
        fig.savefig(figure_path.with_suffix(".svg"), bbox_inches="tight")
        plt.close(fig)
        return

    stages = _ordered_values(plottable["stage"].tolist(), value_orders.get("stage"), default_order=DEFAULT_STAGE_ORDER)
    batches = _ordered_numeric_values(plottable["batch"].tolist())
    seq_values = _ordered_numeric_values(plottable["seq_len"].tolist())
    variants = _ordered_values(plottable["variant"].tolist(), value_orders.get("variant"))
    colors = list(palette or _default_palette())
    group_batch_on_x = x_group_axis == "batch"
    batch_panels = [None] if group_batch_on_x else batches
    x_group_values = batches if group_batch_on_x else [None]
    x_slots, x_group_centers, x_group_boundaries = _energy_x_axis_slots(
        seq_values,
        x_group_values,
        x_group_gap,
    )
    x_positions = [position for _, _, position in x_slots]

    nrows = max(len(stages), 1)
    ncols = max(len(batch_panels), 1)
    fig_width = max(7.0, min(22.0, 2.6 * len(x_slots) + 1.8 * len(variants) + 2.0 * ncols))
    fig_height = max(3.6, 3.0 * nrows + 1.0)
    fig, axes = plt.subplots(
        nrows,
        ncols,
        squeeze=False,
        figsize=figure_size or (fig_width, fig_height),
        sharey=False,
    )
    width, variant_offsets = _bar_width_and_offsets(len(variants), grouped_bar_gap)
    global_max_height = max(_finite_plot_values(plottable[value_col].tolist()), default=1.0)
    row_max_heights = []
    for stage in stages:
        row_subset = plottable[plottable["stage"].astype(str) == str(stage)]
        row_max_heights.append(max(_finite_plot_values(row_subset[value_col].tolist()), default=1.0))

    for row_index, stage in enumerate(stages):
        for col_index, batch in enumerate(batch_panels):
            ax = axes[row_index][col_index]
            subset_filter = plottable["stage"].astype(str) == str(stage)
            if not group_batch_on_x:
                subset_filter = subset_filter & (plottable["batch"].astype(str) == str(batch))
            subset = plottable[subset_filter]
            panel_values = _finite_plot_values(subset[value_col].tolist())
            panel_max_height = max(panel_values, default=1.0)
            label_max_height = {
                "global": global_max_height,
                "row": row_max_heights[row_index],
            }.get(share_y_scope, panel_max_height)
            for variant_index, variant in enumerate(variants):
                offset = variant_offsets[variant_index]
                values = []
                complete_values = []
                for group_batch, seq_len, _ in x_slots:
                    matched_filter = (
                        (subset["variant"].astype(str) == str(variant))
                        & (subset["seq_len"].astype(str) == str(seq_len))
                    )
                    if group_batch_on_x:
                        matched_filter = matched_filter & (subset["batch"].astype(str) == str(group_batch))
                    matched = subset[matched_filter]
                    if matched.empty:
                        values.append(math.nan)
                        complete_values.append(True)
                    else:
                        values.append(float(matched.iloc[0][value_col]))
                        complete_values.append(bool(matched.iloc[0]["complete"]))
                bars = ax.bar(
                    [pos + offset for pos in x_positions],
                    values,
                    width=width,
                    label=_label("variant", variant, label_maps),
                    color=colors[variant_index % len(colors)],
                    edgecolor=bar_edgecolor,
                    linewidth=bar_linewidth,
                    alpha=bar_alpha,
                )
                for bar, is_complete in zip(bars, complete_values):
                    if not is_complete:
                        bar.set_hatch("//")
                        bar.set_alpha(0.7)
                if value_labels:
                    for xpos, value in zip([pos + offset for pos in x_positions], values):
                        if math.isfinite(value):
                            _label_bar(
                                ax,
                                xpos,
                                value,
                                _format_plot_value_label(value, relative),
                                label_max_height,
                                rotation=value_label_rotation,
                                fontsize=value_label_fontsize,
                            )
            ax.set_title(
                (
                    _label("stage", stage, label_maps)
                    if group_batch_on_x
                    else f"{_label('stage', stage, label_maps)}, batch={_format_value(batch)}"
                ),
                fontsize=subplot_title_fontsize,
            )
            if group_batch_on_x:
                _apply_energy_grouped_x_axis(
                    ax,
                    x_slots,
                    x_group_centers,
                    x_group_boundaries,
                    label_maps=label_maps,
                    tick_label_fontsize=tick_label_fontsize,
                    axis_label_fontsize=axis_label_fontsize,
                    x_tick_label_rotation=x_tick_label_rotation,
                    x_tick_label_ha=x_tick_label_ha,
                )
            else:
                ax.set_xticks(x_positions)
                ax.set_xticklabels(
                    [_label("seq_len", value, label_maps) for value in seq_values],
                    rotation=x_tick_label_rotation,
                    ha=x_tick_label_ha,
                )
            _apply_energy_bar_x_limits(ax, x_positions, variant_offsets, width)
            if tick_label_fontsize is not None:
                ax.tick_params(axis="both", labelsize=tick_label_fontsize)
            ax.set_xlabel("" if shared_x_label else "sequence length", fontsize=axis_label_fontsize)
            y_label = "relative J/token" if relative else "J/token"
            ax.set_ylabel(y_label if col_index == 0 else "", fontsize=axis_label_fontsize)
            if share_y_scope == "none":
                ax.set_ylim(0.0, max(panel_max_height, 1.0) * ylim_top_scale)
            ax.grid(axis="y", color="#dddddd", linewidth=0.7)
            ax.set_axisbelow(True)

    if share_y_scope == "global":
        top = max(global_max_height, 1.0) * ylim_top_scale
        for ax in axes.flat:
            ax.set_ylim(0.0, top)
    elif share_y_scope == "row":
        for row_index, row_max_height in enumerate(row_max_heights):
            top = max(row_max_height, 1.0) * ylim_top_scale
            for ax in axes[row_index]:
                ax.set_ylim(0.0, top)

    if share_y_scope in {"global", "row"}:
        for col_index in range(1, ncols):
            for ax in axes[:, col_index]:
                ax.tick_params(axis="y", left=False, labelleft=False)

    if shared_x_label:
        fig.supxlabel(
            "sequence length",
            fontsize=axis_label_fontsize,
            **_shared_x_label_kwargs(legend_position, shared_x_label_y),
        )

    handles, labels = axes[0][0].get_legend_handles_labels()
    legend_drawn = _add_energy_legend(
        fig,
        handles,
        labels,
        legend_title=legend_title,
        legend_position=legend_position,
        legend_fontsize=legend_fontsize,
        legend_title_fontsize=legend_title_fontsize,
    )
    if not plottable["complete"].astype(bool).all():
        fig.text(
            0.5,
            -0.01,
            "Hatched bars have at least one kernel without a matched or imputed power value.",
            ha="center",
            va="top",
            fontsize=legend_fontsize or 9,
        )
    default_title = "E2E energy per token"
    metric_label = _summary_power_metric_label(summary_df)
    fig.suptitle(f"{title or default_title} ({metric_label}, fpga cycles)", y=0.99, fontsize=title_fontsize)
    bottom = 0.12 if legend_drawn and legend_position == "bottom" else 0.0
    fig.tight_layout(rect=(0.0, bottom, 1.0, FIGURE_TITLE_LAYOUT_TOP))
    _apply_energy_subplot_spacing(fig, subplot_wspace, subplot_hspace)
    fig.savefig(figure_path, bbox_inches="tight", dpi=save_dpi)
    fig.savefig(figure_path.with_suffix(".svg"), bbox_inches="tight")
    plt.close(fig)


def _validate_energy_plot_layout_options(
    share_y_scope: str,
    subplot_wspace: float | None,
    subplot_hspace: float | None,
    x_group_axis: str | None,
    x_group_gap: float,
    shared_x_label_y: float | None,
) -> None:
    if share_y_scope not in SHARE_Y_SCOPE_CHOICES:
        raise ValueError(
            f"unsupported share y scope: {share_y_scope}; "
            f"expected one of {', '.join(SHARE_Y_SCOPE_CHOICES)}"
        )
    if x_group_axis not in (None, "batch"):
        raise ValueError("x_group_axis currently supports only batch")
    if float(x_group_gap) < 0.0:
        raise ValueError("x_group_gap must be non-negative")
    for name, value in (("subplot_wspace", subplot_wspace), ("subplot_hspace", subplot_hspace)):
        if value is not None and float(value) < 0.0:
            raise ValueError(f"{name} must be non-negative when set")
    if shared_x_label_y is not None and not 0.0 <= float(shared_x_label_y) <= 1.0:
        raise ValueError("shared_x_label_y must be between 0 and 1 when set")


def _apply_energy_subplot_spacing(
    fig: Any,
    subplot_wspace: float | None,
    subplot_hspace: float | None,
) -> None:
    spacing = {}
    if subplot_wspace is not None:
        spacing["wspace"] = subplot_wspace
    if subplot_hspace is not None:
        spacing["hspace"] = subplot_hspace
    if spacing:
        fig.subplots_adjust(**spacing)


def _shared_x_label_kwargs(legend_position: str, shared_x_label_y: float | None = None) -> dict[str, float]:
    if shared_x_label_y is not None:
        return {"y": float(shared_x_label_y)}
    if legend_position == "bottom":
        return {"y": 0.13}
    return {}


def _add_energy_legend(
    fig: Any,
    handles: Sequence[Any],
    labels: Sequence[str],
    *,
    legend_title: str | None,
    legend_position: str,
    legend_fontsize: float | None = None,
    legend_title_fontsize: float | None = None,
) -> bool:
    if not handles or legend_position == "none":
        return False
    ncol = min(len(labels), 4)
    if legend_position == "bottom":
        fig.legend(
            handles,
            labels,
            title=legend_title,
            loc="lower center",
            bbox_to_anchor=(0.5, 0.02),
            ncol=ncol,
            fontsize=legend_fontsize,
            title_fontsize=legend_title_fontsize,
        )
        return True
    if legend_position == "top_right":
        fig.legend(
            handles,
            labels,
            title=legend_title,
            loc="upper right",
            bbox_to_anchor=(0.995, 0.995),
            ncol=ncol,
            fontsize=legend_fontsize,
            title_fontsize=legend_title_fontsize,
        )
        return True
    raise ValueError(f"unsupported energy legend position: {legend_position}")


def _summary_power_metric_label(summary_df: Any) -> str:
    if not hasattr(summary_df, "columns") or "power_metric" not in summary_df.columns:
        return DEFAULT_POWER_METRIC
    try:
        values = [str(value) for value in summary_df["power_metric"].dropna().unique() if str(value)]
    except Exception:
        return DEFAULT_POWER_METRIC
    return values[0] if values else DEFAULT_POWER_METRIC


def _canonical_power_metric(value: Any) -> str:
    metric = _text(value) or DEFAULT_POWER_METRIC
    if metric in POWER_METRIC_COLUMN_ALIASES:
        return metric
    if metric.endswith("_w"):
        upper_metric = f"{metric[:-2]}_W"
        if upper_metric in POWER_METRIC_COLUMN_ALIASES:
            return upper_metric
    return metric


def _power_metric_columns(metric: str) -> tuple[str, ...]:
    canonical = _canonical_power_metric(metric)
    if canonical in POWER_METRIC_COLUMN_ALIASES:
        return POWER_METRIC_COLUMN_ALIASES[canonical]
    if canonical.endswith("_W"):
        return (canonical, f"{canonical[:-2]}_w")
    return (canonical,)


def _power_value(row: Mapping[str, Any], metric: str) -> float | None:
    for column in _power_metric_columns(metric):
        value = _to_float(row.get(column))
        if value is not None:
            return value
    return None


def _weighted_fpga_cycles(row: Mapping[str, Any], exact_candidate: PowerCandidate | None = None) -> float | None:
    fpga_cycle_avg = _fpga_cycle_avg(row, exact_candidate)
    if fpga_cycle_avg is None:
        return None
    calls = _to_float(row.get("calls_per_forward")) or 1.0
    return fpga_cycle_avg * calls


def _fpga_cycle_avg(row: Mapping[str, Any], exact_candidate: PowerCandidate | None = None) -> float | None:
    for key in ("fpga_cycle_avg", "fpga_cycle"):
        value = _to_float(row.get(key))
        if value is not None:
            return value
    if _text(row.get("metric")) == "fpga_cycle":
        value = _to_float(row.get("latency_us"))
        if value is not None:
            return value
    if exact_candidate is not None:
        return exact_candidate.fpga_cycle_avg
    return None


def _fpga_period_s(
    row: Mapping[str, Any],
    candidate: PowerCandidate | None,
    *,
    default: float,
) -> float | None:
    for context in _period_contexts(row, candidate):
        explicit = _first_float(context, ("fpga_period_s", "power_fpga_period_s"))
        if explicit is not None and explicit > 0.0:
            return explicit
        freq_mhz = _first_float(
            context,
            (
                "fpga_freq_mhz",
                "power_fpga_freq_mhz",
                "power_fpga_freq_MHz",
                "clock_mhz",
                "clock_MHz",
            ),
        )
        if freq_mhz is not None and freq_mhz > 0.0:
            return 1.0 / (freq_mhz * 1_000_000.0)
        for info_path in _xclbin_info_paths(context):
            period_s = _kernel_clock_period_s_from_xclbin_info(info_path)
            if period_s is not None:
                return period_s
    return default if default > 0.0 else None


def _period_contexts(
    row: Mapping[str, Any],
    candidate: PowerCandidate | None,
) -> tuple[Mapping[str, Any], ...]:
    if candidate is None:
        return (row,)
    return (row, candidate.row)


def _first_float(row: Mapping[str, Any], keys: Sequence[str]) -> float | None:
    for key in keys:
        value = _to_float(row.get(key))
        if value is not None:
            return value
    return None


def _xclbin_info_paths(row: Mapping[str, Any]) -> list[Path]:
    paths: list[Path] = []
    for key in ("xclbin_info", "xclbin_info_path", "power_xclbin_info", "power_xclbin_info_path"):
        value = _text(row.get(key))
        if value:
            paths.append(Path(value).expanduser())
    for key in ("xclbin_path", "xrt_xclbin_path", "XRT_XCLBIN_PATH"):
        value = _text(row.get(key))
        if value:
            paths.append(Path(f"{value}.info").expanduser())
    fpga_bin_dir = _text(row.get("fpga_bin_dir"))
    if fpga_bin_dir:
        paths.extend(_xclbin_info_paths_for_bin_dir(Path(fpga_bin_dir).expanduser()))
    for label in _fpga_bin_labels(row):
        resolved_dir = _resolve_fpga_bin_dir(label)
        if resolved_dir is not None:
            paths.extend(_xclbin_info_paths_for_bin_dir(resolved_dir))
    return _existing_unique_paths(paths)


def _xclbin_info_paths_for_bin_dir(bin_dir: Path) -> list[Path]:
    return [bin_dir / filename for filename in XCLBIN_INFO_FILENAMES]


def _fpga_bin_labels(row: Mapping[str, Any]) -> list[str]:
    labels: list[str] = []
    for key in ("expected_fpga_bin_label", "fpga_bin_label"):
        value = _text(row.get(key))
        if value:
            labels.append(value)
    source_labels = _text(row.get("source_fpga_bin_labels"))
    if source_labels:
        labels.extend(label.strip() for label in source_labels.split(";") if label.strip())
    return list(dict.fromkeys(labels))


@lru_cache(maxsize=None)
def _resolve_fpga_bin_dir(label: str) -> Path | None:
    try:
        return resolve_fpga_bin_config(label).path
    except Exception:
        return None


def _existing_unique_paths(paths: Iterable[Path]) -> list[Path]:
    out: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        resolved = path.expanduser()
        key = str(resolved)
        if key in seen or not resolved.exists():
            continue
        seen.add(key)
        out.append(resolved)
    return out


@lru_cache(maxsize=None)
def _kernel_clock_period_s_from_xclbin_info(path: Path) -> float | None:
    in_kernel_clock = False
    try:
        with path.open(errors="ignore") as handle:
            for line in handle:
                if "Name:" in line:
                    in_kernel_clock = "ulp_ucs_aclk_kernel_00" in line
                if not in_kernel_clock or "Achieved Freq:" not in line:
                    continue
                freq_mhz = _parse_frequency_mhz_line(line)
                if freq_mhz is not None and freq_mhz > 0.0:
                    return 1.0 / (freq_mhz * 1_000_000.0)
    except OSError:
        return None
    return None


def _period_s_from_info_line(line: str) -> float | None:
    if "Period:" in line:
        period_s = _parse_period_s_line(line)
        if period_s is not None:
            return period_s
    if "Frequency:" in line:
        freq_mhz = _parse_frequency_mhz_line(line)
        if freq_mhz is not None and freq_mhz > 0.0:
            return 1.0 / (freq_mhz * 1_000_000.0)
    return None


def _parse_frequency_mhz_line(line: str) -> float | None:
    number = _number_after_colon(line)
    if number is None or number <= 0.0:
        return None
    lowered = line.lower()
    if "ghz" in lowered:
        return number * 1_000.0
    if "khz" in lowered:
        return number / 1_000.0
    if re.search(r"\bhz\b", lowered) and "mhz" not in lowered:
        return number / 1_000_000.0
    return number


def _parse_period_s_line(line: str) -> float | None:
    number = _number_after_colon(line)
    if number is None or number <= 0.0:
        return None
    lowered = line.lower()
    if "ps" in lowered:
        return number * 1e-12
    if "us" in lowered:
        return number * 1e-6
    if "ms" in lowered:
        return number * 1e-3
    if re.search(r"\bs\b", lowered) and "ns" not in lowered:
        return number
    return number * 1e-9


def _number_after_colon(line: str) -> float | None:
    text = line.split(":", 1)[1] if ":" in line else line
    match = re.search(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", text)
    return _to_float(match.group(0)) if match else None


def _shape_for_row(row: Mapping[str, Any]) -> dict[str, Any]:
    shape = _parse_shape(row.get("shape_json"))
    for key in ("batch", "seq_len"):
        value = row.get(key)
        if value not in (None, ""):
            shape.setdefault(key, value)
    return _normalize_shape_keys(shape)


def _parse_shape(value: Any) -> dict[str, Any]:
    if value in (None, ""):
        return {}
    if isinstance(value, Mapping):
        return dict(value)
    if not isinstance(value, str):
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return {}
    return dict(parsed) if isinstance(parsed, Mapping) else {}


def _normalize_shape_keys(shape: Mapping[str, Any]) -> dict[str, Any]:
    normalized = {}
    for key, value in shape.items():
        normalized[str(key).strip().lower()] = value
    return normalized


def _relative_group_key(row: Mapping[str, Any], relative_scope: str) -> tuple[Any, ...]:
    if relative_scope == "global":
        return ()
    if relative_scope == "subplot":
        return (row.get("stage"), row.get("batch"))
    if relative_scope == "x_tick":
        return (row.get("stage"), row.get("batch"), row.get("seq_len"))
    raise ValueError(f"unsupported relative scope: {relative_scope}")


def _series_relative_baseline(values: Iterable[Any]) -> float:
    positive = [value for value in (_to_float(item) for item in values) if value is not None and value > 0]
    return min(positive) if positive else 1.0


def _finite_plot_values(values: Iterable[Any]) -> list[float]:
    finite = []
    for value in values:
        number = _to_float(value)
        if number is not None:
            finite.append(number)
    return finite


def _label_offset(max_height: float) -> float:
    return max(float(max_height), 1.0) * 0.01


def _label_bar(
    ax: Any,
    xpos: float,
    height: float,
    text: str,
    max_height: float,
    *,
    rotation: float = 0.0,
    fontsize: float = 7.0,
) -> None:
    ax.text(
        xpos,
        height + _label_offset(max_height),
        text,
        ha="center",
        va="bottom",
        rotation=rotation,
        fontsize=fontsize,
    )


def _format_plot_value_label(value: float, relative: bool) -> str:
    return f"{value:.3f}x" if relative else f"{value:.3f}"


def _bar_width_and_offsets(hue_count: int, grouped_bar_gap: float) -> tuple[float, list[float]]:
    count = max(1, int(hue_count))
    group_width = 0.8
    gap = float(grouped_bar_gap)
    available_width = group_width - gap * (count - 1)
    if available_width <= 0.0:
        raise ValueError(
            f"grouped_bar_gap={gap:g} is too large for {count} bars; "
            f"gap must be smaller than {group_width / max(count - 1, 1):g}"
        )
    bar_width = min(available_width / count, 0.28)
    center_step = bar_width + gap
    offsets = [
        (idx - (count - 1) / 2.0) * center_step
        for idx in range(count)
    ]
    return bar_width, offsets


def _normalize_energy_x_group_axis(x_group_axis: str | None) -> str | None:
    if x_group_axis is None:
        return None
    normalized = str(x_group_axis).strip().lower()
    return normalized or None


def _energy_x_axis_slots(
    seq_values: list[Any],
    group_values: list[Any | None],
    group_gap: float,
) -> tuple[list[tuple[Any | None, Any, float]], list[tuple[Any | None, float]], list[float]]:
    slots: list[tuple[Any | None, Any, float]] = []
    centers: list[tuple[Any | None, float]] = []
    boundaries: list[float] = []
    group_step = len(seq_values) + float(group_gap)
    previous_last: float | None = None
    for group_index, group_value in enumerate(group_values):
        base = group_index * group_step
        positions = [base + seq_index for seq_index, _ in enumerate(seq_values)]
        if positions:
            centers.append((group_value, sum(positions) / len(positions)))
            if previous_last is not None:
                boundaries.append((previous_last + positions[0]) / 2.0)
            previous_last = positions[-1]
        for seq_len, position in zip(seq_values, positions):
            slots.append((group_value, seq_len, position))
    return slots, centers, boundaries


def _apply_energy_grouped_x_axis(
    ax: Any,
    slots: list[tuple[Any | None, Any, float]],
    group_centers: list[tuple[Any | None, float]],
    group_boundaries: list[float],
    *,
    label_maps: Mapping[str, Mapping[Any, str]],
    tick_label_fontsize: float | None,
    axis_label_fontsize: float | None,
    x_tick_label_rotation: float,
    x_tick_label_ha: str,
) -> None:
    ax.set_xticks([position for _, _, position in slots])
    ax.set_xticklabels(
        [_label("seq_len", seq_len, label_maps) for _, seq_len, _ in slots],
        rotation=x_tick_label_rotation,
        ha=x_tick_label_ha,
    )
    label_size = tick_label_fontsize or axis_label_fontsize
    for group_value, center in group_centers:
        ax.text(
            center,
            -0.18,
            f"batch={_label('batch', group_value, label_maps)}",
            transform=ax.get_xaxis_transform(),
            ha="center",
            va="top",
            fontsize=label_size,
        )
    for boundary in group_boundaries:
        ax.axvline(boundary, color="#999999", linewidth=0.6, alpha=0.65)


def _apply_energy_bar_x_limits(
    ax: Any,
    x_positions: list[float],
    variant_offsets: list[float],
    bar_width: float,
) -> None:
    if not x_positions:
        return
    offsets = variant_offsets or [0.0]
    edge_padding = bar_width * 0.25
    left = min(x_positions) + min(offsets) - bar_width / 2.0 - edge_padding
    right = max(x_positions) + max(offsets) + bar_width / 2.0 + edge_padding
    ax.set_xlim(left, right)


def _split_shape(shape: Mapping[str, Any]) -> tuple[dict[str, float], dict[str, str]]:
    numeric: dict[str, float] = {}
    categorical: dict[str, str] = {}
    for key, value in shape.items():
        number = _to_float(value)
        if number is not None:
            numeric[key] = number
        elif value not in (None, ""):
            categorical[key] = str(value)
    return numeric, categorical


def _shape_distance(
    *,
    target_numeric: Mapping[str, float],
    target_categorical: Mapping[str, str],
    target_stage: str,
    candidate: PowerCandidate,
) -> float:
    distance = 0.0
    numeric_keys = set(target_numeric) | set(candidate.numeric_shape)
    for key in numeric_keys:
        left = target_numeric.get(key)
        right = candidate.numeric_shape.get(key)
        if left is None or right is None:
            distance += 4.0
        else:
            distance += abs(math.log2((max(left, 0.0) + 1.0) / (max(right, 0.0) + 1.0)))

    categorical_keys = set(target_categorical) | set(candidate.categorical_shape)
    for key in categorical_keys:
        left = target_categorical.get(key)
        right = candidate.categorical_shape.get(key)
        if left is None or right is None:
            distance += 1.0
        elif left != right:
            distance += 2.0

    if target_stage and candidate.stage and target_stage != candidate.stage:
        distance += 1.0
    return distance


def _candidate_rank(
    distance: float,
    target_stage: str,
    candidate: PowerCandidate | None,
) -> tuple[float, int, int, str, str]:
    if candidate is None:
        return (math.inf, 1, 0, "", "")
    stage_mismatch = int(bool(target_stage and candidate.stage and target_stage != candidate.stage))
    return (
        distance,
        stage_mismatch,
        -candidate.power_samples,
        candidate.fpga_bin_label,
        candidate.args,
    )


def _best_exact_candidate(candidates: Iterable[PowerCandidate]) -> PowerCandidate:
    return min(candidates, key=lambda candidate: (-candidate.power_samples, candidate.args))


def _weighted_latency_us(row: Mapping[str, Any]) -> float | None:
    weighted = _to_float(row.get("weighted_latency_us"))
    if weighted is not None:
        return weighted
    latency = _to_float(row.get("latency_us"))
    calls = _to_float(row.get("calls_per_forward")) or 1.0
    return latency * calls if latency is not None else None


def _token_count(row: Mapping[str, Any]) -> float | None:
    stage = _stage(row)
    batch = _batch(row)
    seq_len = _seq_len(row)
    if batch is None:
        return None
    if stage == GENERATION_STAGE:
        out_tokens = _out_tokens(row)
        return batch * out_tokens
    if seq_len is None:
        return None
    return batch * seq_len


def _out_tokens(row: Mapping[str, Any]) -> int:
    value = _to_int(row.get("out_tokens"))
    if value is not None and value > 0:
        return value
    shape = _shape_for_row(row)
    value = _to_int(shape.get("out_tokens"))
    return value if value is not None and value > 0 else 1


def _batch(row: Mapping[str, Any]) -> int | None:
    for key in ("batch", "energy_batch"):
        value = _to_int(row.get(key))
        if value is not None:
            return value
    shape = _shape_for_row(row)
    value = _to_int(shape.get("batch"))
    if value is not None:
        return value
    match = re.search(r"(?:^|_)batch(\d+)(?:_|$)", _text(row.get("case_id")))
    return int(match.group(1)) if match else None


def _seq_len(row: Mapping[str, Any]) -> int | None:
    if _stage(row) == GENERATION_STAGE:
        value = _to_int(row.get("gen_kv_len"))
        if value is not None:
            return value
        shape = _shape_for_row(row)
        value = _to_int(shape.get("input_kv_length"))
        if value is not None:
            return value
    for key in ("seq_len", "energy_seq_len"):
        value = _to_int(row.get(key))
        if value is not None:
            return value
    shape = _shape_for_row(row)
    for key in ("seq_len", "seq", "seqq", "seqk", "tokens"):
        value = _to_int(shape.get(key))
        if value is not None:
            return value
    case_id = _text(row.get("case_id"))
    for pattern in (
        r"(?:^|_)prefill_seq_len(\d+)(?:_|$)",
        r"(?:^|_)gen_kv_len(\d+)(?:_|$)",
        r"(?:^|_)generation_seq_len(\d+)(?:_|$)",
        r"(?:^|_)seq_len(\d+)(?:_|$)",
    ):
        match = re.search(pattern, case_id)
        if match:
            return int(match.group(1))
    return None


def _stage(row: Mapping[str, Any]) -> str:
    return _text(row.get("stage") or row.get("energy_stage")).lower()


def _target_fpga_bin_label(row: Mapping[str, Any]) -> str:
    for key in ("expected_fpga_bin_label", "fpga_bin_label"):
        value = _text(row.get(key))
        if value:
            return value
    labels = _text(row.get("source_fpga_bin_labels"))
    if labels:
        return labels.split(";")[0].strip()
    return ""


def _summary_sort_key(row: Mapping[str, Any]) -> tuple[Any, ...]:
    stage = _text(row.get("stage"))
    try:
        stage_index = DEFAULT_STAGE_ORDER.index(stage)
    except ValueError:
        stage_index = len(DEFAULT_STAGE_ORDER)
    return (
        stage_index,
        _numeric_sort_value(row.get("batch")),
        _numeric_sort_value(row.get("seq_len")),
        _text(row.get("variant")),
    )


def _ordered_values(
    values: Sequence[Any],
    order: Sequence[Any] | None = None,
    *,
    default_order: Sequence[Any] = (),
) -> list[Any]:
    unique = list(dict.fromkeys(values))
    configured = list(order or default_order)
    ordered = [value for value in configured if str(value) in {str(item) for item in unique}]
    ordered.extend(sorted((value for value in unique if str(value) not in {str(item) for item in ordered}), key=str))
    return ordered


def _ordered_numeric_values(values: Sequence[Any]) -> list[Any]:
    unique = list(dict.fromkeys(values))
    return sorted(unique, key=_numeric_sort_value)


def _numeric_sort_value(value: Any) -> tuple[int, float | str]:
    number = _to_float(value)
    if number is None:
        return (1, _text(value))
    return (0, number)


def _label(axis: str, value: Any, label_maps: Mapping[str, Mapping[Any, str]]) -> str:
    axis_map = label_maps.get(axis, {})
    if value in axis_map:
        return str(axis_map[value])
    text_value = str(value)
    for raw_value, label in axis_map.items():
        if str(raw_value) == text_value:
            return str(label)
    return _format_value(value)


def _format_value(value: Any) -> str:
    number = _to_float(value)
    if number is not None and number.is_integer():
        return str(int(number))
    return str(value)


def _default_palette() -> tuple[str, ...]:
    return (
        "#08306B",
        "#2171B5",
        "#6BAED6",
        "#00441B",
        "#238B45",
        "#74C476",
        "#7F2704",
        "#D94801",
    )


def _write_dict_csv(
    path: Path,
    rows: Sequence[Mapping[str, Any]],
    *,
    preferred_fields: Sequence[str] = (),
) -> None:
    fieldnames = list(preferred_fields)
    for row in rows:
        for field in row:
            if field not in fieldnames:
                fieldnames.append(field)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: _csv_value(row.get(field)) for field in fieldnames})


def _csv_value(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return value


def _to_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return float(value)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _to_int(value: Any) -> int | None:
    number = _to_float(value)
    if number is None:
        return None
    return int(number)


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value)
