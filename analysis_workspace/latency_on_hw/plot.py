#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Sequence


DEFAULT_PREPARED_ROOT = "outputs_main_small/figures_prepare"
DEFAULT_OUT_DIR = "outputs_main_small/figures_script"
PLOT_CHOICES = ("main_all", "gemm_only", "energy", "llama_e2e", "latency", "all")
EXCEL_FIGURE_DATA_CSV = "excel_figure_data.csv"

TWO_COLUMN_FIGSIZE = (7.16, 3.0)
GEMM_FIGSIZE = (7.16, 4.2)
LLAMA_E2E_FIGSIZE = (7.16, 5.8)
SAVE_DPI = 600
BAR_EDGECOLOR = "white"
BAR_LINEWIDTH = 0.25
BAR_ALPHA = 1.0

FIGURE_TITLE = None
MAIN_ALL_TITLE = "E2E latency"
GEMM_ONLY_TITLE = "GEMM latency breakdown"
ENERGY_TITLE = "E2E energy per token"
LLAMA_E2E_TITLE = "Llama 2 and Llama 3 E2E latency"
SUBPLOT_TITLE_TEMPLATE = "{stage}"
LLAMA_E2E_SUBPLOT_TITLE_TEMPLATE = "{model}, {stage}"
X_LABEL = "sequence length"
Y_LABEL = "relative latency"
ENERGY_Y_LABEL = "relative energy"
LEGEND_TITLE = "candidate"
LEGEND_NCOL = 4
GEMM_LEGEND_TITLE = "kernel"

TITLE_FONTSIZE = 8.0
SUBPLOT_TITLE_FONTSIZE = 7.2
AXIS_LABEL_FONTSIZE = 6.6
TICK_LABEL_FONTSIZE = 6.2
LEGEND_FONTSIZE = 5.4
LEGEND_TITLE_FONTSIZE = 5.6
VALUE_LABEL_FONTSIZE = 4.0

X_GROUP_AXIS = "batch"
X_GROUP_GAP = 0.35
VALUE_LABELS = True
E2E_CANDIDATE_COLUMNS = ("C1", "C2", "C3", "C4")
STAGE_ORDER = ("Prefill", "Generation")
LLAMA_E2E_MODELS = (
    ("llama2_7b", "Llama 2"),
    ("llama3_8b", "Llama 3"),
)
LLAMA_E2E_ROW_ORDER = (
    ("Llama 2", "Prefill"),
    ("Llama 2", "Generation"),
    ("Llama 3", "Prefill"),
    ("Llama 3", "Generation"),
)

BAR_PALETTE = (
    "#08306B",
    "#2171B5",
    "#6BAED6",
    "#74C476",
    "#F28E2B",
    "#E15759",
)
GEMM_ONLY_STACK_PALETTE = (
    "#4D4D4D",
    "#7F7F7F",
    "#BDBDBD",
    "#08306B",
    "#2171B5",
    "#6BAED6",
    "#00441B",
    "#238B45",
    "#74C476",
    "#016C59",
    "#3690C0",
    "#A1D99B",
)


@dataclass
class WideBarKnobs:
    figsize: tuple[float, float] = TWO_COLUMN_FIGSIZE
    row_height: float | None = None
    dpi: int = SAVE_DPI
    title: str | None = None
    subplot_title_template: str = SUBPLOT_TITLE_TEMPLATE
    x_label: str = X_LABEL
    y_label: str = Y_LABEL
    title_fontsize: float = TITLE_FONTSIZE
    subplot_title_fontsize: float = SUBPLOT_TITLE_FONTSIZE
    axis_label_fontsize: float = AXIS_LABEL_FONTSIZE
    tick_label_fontsize: float = TICK_LABEL_FONTSIZE
    legend_fontsize: float = LEGEND_FONTSIZE
    legend_title_fontsize: float = LEGEND_TITLE_FONTSIZE
    bar_width: float = 0.18
    bar_edgecolor: str = BAR_EDGECOLOR
    bar_linewidth: float = BAR_LINEWIDTH
    bar_alpha: float = BAR_ALPHA
    palette: tuple[str, ...] | None = None
    value_labels: bool = VALUE_LABELS
    value_label_format: str = "{:.2g}"
    value_label_fontsize: float = VALUE_LABEL_FONTSIZE
    value_label_rotation: float = 90.0
    value_label_ha: str = "center"
    value_label_va: str = "bottom"
    value_label_dy: float = 0.0
    x_group_axis: str | None = X_GROUP_AXIS
    x_group_gap: float = X_GROUP_GAP
    y_lim_top_scale: float = 1.25
    y_lim: tuple[float | None, float | None] | None = None
    stage_y_lims: dict[str, tuple[float | None, float | None]] = field(default_factory=dict)
    grid_alpha: float = 0.25
    legend_position: str = "top"  # top, bottom, or none
    legend_title: str | None = LEGEND_TITLE
    legend_ncol: int | None = LEGEND_NCOL
    legend_loc: str | None = None
    legend_bbox_to_anchor: tuple[float, float] | None = None
    suptitle_y: float = 0.995
    legend_y: float = 0.94
    tight_layout_rect: tuple[float, float, float, float] = (0.0, 0.04, 1.0, 0.88)
    save_png: bool = True
    save_pdf: bool = True
    save_svg: bool = True


@dataclass
class StackedBarKnobs(WideBarKnobs):
    figsize: tuple[float, float] = GEMM_FIGSIZE
    row_height: float | None = 2.1
    bar_width: float = 0.76
    y_lim_top_scale: float = 1.18
    legend_title: str | None = GEMM_LEGEND_TITLE
    legend_ncol: int | None = 6
    legend_position: str = "bottom"
    legend_y: float = -0.32
    tight_layout_rect: tuple[float, float, float, float] = (0.0, 0.08, 1.0, 0.96)
    stack_palette: tuple[str, ...] | None = None


@dataclass
class PlotKnobs:
    main_all: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=TWO_COLUMN_FIGSIZE,
            row_height=TWO_COLUMN_FIGSIZE[1],
            title=MAIN_ALL_TITLE,
            y_label=Y_LABEL,
        )
    )
    gemm_only: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            title=GEMM_ONLY_TITLE,
            y_label=Y_LABEL,
        )
    )
    energy: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=TWO_COLUMN_FIGSIZE,
            row_height=TWO_COLUMN_FIGSIZE[1],
            title=ENERGY_TITLE,
            y_label=ENERGY_Y_LABEL,
        )
    )
    llama_e2e: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=LLAMA_E2E_FIGSIZE,
            row_height=LLAMA_E2E_FIGSIZE[1] / len(LLAMA_E2E_ROW_ORDER),
            title=LLAMA_E2E_TITLE,
            subplot_title_template=LLAMA_E2E_SUBPLOT_TITLE_TEMPLATE,
            y_label=Y_LABEL,
            legend_y=0.965,
            tight_layout_rect=(0.0, 0.04, 1.0, 0.92),
        )
    )


# User-editable plot controls. This replaces the old plot.ipynb knob cell while
# keeping plot.py runnable as a pure Python script.
PLOT_KNOBS = PlotKnobs()


@dataclass
class EnergyExcelResult:
    summary: Any
    figure_path: Path


def find_repo_root(start: Path | None = None) -> Path:
    path = Path.cwd() if start is None else start
    for candidate in (path.resolve(), *path.resolve().parents):
        if (candidate / "tools" / "latency_bench").is_dir():
            return candidate
    raise RuntimeError("failed to find Vortex repository root")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate figures from prepared latency excel_figure_data.csv files.",
    )
    parser.add_argument(
        "--plot",
        choices=PLOT_CHOICES,
        default="all",
        help="plot to generate: main_all, gemm_only, energy, llama_e2e, latency, or all",
    )
    parser.add_argument(
        "--latency-dir",
        default=None,
        help="latency workspace directory. Defaults to analysis_workspace/latency_on_hw under the repo root.",
    )
    parser.add_argument(
        "--prepared-root",
        default=DEFAULT_PREPARED_ROOT,
        help="directory containing prepared figure subdirectories. Relative paths are resolved under --latency-dir.",
    )
    parser.add_argument(
        "--out-dir",
        default=DEFAULT_OUT_DIR,
        help="output root. Relative paths are resolved under --latency-dir.",
    )
    parser.add_argument(
        "--main-data",
        default=None,
        help="main_all prepared directory or excel_figure_data.csv. Defaults to auto-discovery.",
    )
    parser.add_argument(
        "--gemm-data",
        default=None,
        help="gemm_only prepared directory or excel_figure_data.csv. Defaults to auto-discovery.",
    )
    parser.add_argument(
        "--energy-data",
        default=None,
        help="energy_per_token prepared directory or excel_figure_data.csv. Defaults to auto-discovery.",
    )
    parser.add_argument(
        "--llama2-data",
        default=None,
        help="Llama 2 E2E prepared directory or excel_figure_data.csv for --plot llama_e2e.",
    )
    parser.add_argument(
        "--llama3-data",
        default=None,
        help="Llama 3 E2E prepared directory or excel_figure_data.csv for --plot llama_e2e.",
    )
    parser.add_argument(
        "--figure-width",
        type=float,
        default=None,
        help="override output figure width in inches.",
    )
    parser.add_argument(
        "--row-height",
        type=float,
        default=None,
        help="override per-row figure height in inches for multi-row plots.",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="override the selected plot title.",
    )
    parser.add_argument(
        "--subplot-title-template",
        default=None,
        help="override subplot titles. Use {stage}; llama_e2e also supports {model}.",
    )
    parser.add_argument(
        "--x-label",
        default=None,
        help=f"override x-axis label. Default: {X_LABEL!r}.",
    )
    parser.add_argument(
        "--y-label",
        default=None,
        help=f"override y-axis label. Default: {Y_LABEL!r}.",
    )
    parser.add_argument(
        "--legend-title",
        default=None,
        help=f"override legend title. Default: {LEGEND_TITLE!r}.",
    )
    parser.add_argument(
        "--legend-ncol",
        type=int,
        default=None,
        help=f"override legend column count. Default: {LEGEND_NCOL}.",
    )
    parser.add_argument(
        "--x-group-axis",
        choices=("none", "batch"),
        default=X_GROUP_AXIS,
        help="include this axis in grouped x labels. Default: %(default)s",
    )
    parser.add_argument(
        "--x-group-gap",
        type=float,
        default=X_GROUP_GAP,
        help=f"visual gap between x-axis groups when grouping is enabled (default: {X_GROUP_GAP:g})",
    )
    parser.add_argument(
        "--excel-only",
        action="store_true",
        help="deprecated no-op; plot.py already consumes prepared excel_figure_data.csv files only.",
    )
    value_labels = parser.add_mutually_exclusive_group()
    value_labels.add_argument(
        "--value-labels",
        dest="value_labels",
        action="store_true",
        default=None,
        help="show numeric labels above bars.",
    )
    value_labels.add_argument(
        "--no-value-labels",
        dest="value_labels",
        action="store_false",
        help="hide numeric labels above bars.",
    )
    return parser.parse_args(argv)


def _import_plot_modules() -> tuple[Any, Any]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import pandas as pd

    return pd, plt


def resolve_under_latency_dir(path: str | Path, latency_dir: Path, *, prefer_existing: bool = False) -> Path:
    resolved = Path(path).expanduser()
    if resolved.is_absolute():
        return resolved.resolve()
    if prefer_existing and resolved.exists():
        return resolved.resolve()
    resolved = latency_dir / resolved
    return resolved.resolve()


def _prepared_csv_from_path(path: Path) -> Path:
    return path if path.name == EXCEL_FIGURE_DATA_CSV else path / EXCEL_FIGURE_DATA_CSV


def _candidate_matches_kind(path: Path, kind: str) -> bool:
    name = path.parent.name if path.name == EXCEL_FIGURE_DATA_CSV else path.name
    if kind == "main_all":
        return "gemm_only" not in name and "energy_per_token" not in name and "llama_compare" not in name
    if kind == "gemm_only":
        return "gemm_only" in name
    if kind == "energy":
        return "energy_per_token" in name
    raise ValueError(f"unsupported prepared data kind: {kind}")


def _discover_prepared_csv(prepared_root: Path, kind: str) -> Path:
    if not prepared_root.exists():
        raise FileNotFoundError(f"prepared root does not exist: {prepared_root}")
    candidates = [
        path
        for path in prepared_root.glob(f"*/{EXCEL_FIGURE_DATA_CSV}")
        if _candidate_matches_kind(path, kind)
    ]
    if not candidates:
        raise FileNotFoundError(f"no {kind} {EXCEL_FIGURE_DATA_CSV} found under {prepared_root}")
    candidates.sort(key=lambda path: (path.stat().st_mtime, str(path)), reverse=True)
    selected = candidates[0]
    print(f"{kind} data: {selected}")
    return selected


def _discover_model_e2e_csv(prepared_root: Path, model_key: str) -> Path:
    if not prepared_root.exists():
        raise FileNotFoundError(f"prepared root does not exist: {prepared_root}")
    candidates = []
    for path in prepared_root.glob(f"*/{EXCEL_FIGURE_DATA_CSV}"):
        name = path.parent.name
        if model_key not in name:
            continue
        if not _candidate_matches_kind(path, "main_all"):
            continue
        candidates.append(path)
    if not candidates:
        raise FileNotFoundError(f"no {model_key} E2E {EXCEL_FIGURE_DATA_CSV} found under {prepared_root}")
    candidates.sort(key=lambda path: (path.stat().st_mtime, str(path)), reverse=True)
    selected = candidates[0]
    print(f"{model_key} E2E data: {selected}")
    return selected


def prepared_csv_path(
    *,
    explicit: str | None,
    prepared_root: Path,
    latency_dir: Path,
    kind: str,
) -> Path:
    if explicit:
        csv_path = _prepared_csv_from_path(resolve_under_latency_dir(explicit, latency_dir, prefer_existing=True))
    else:
        csv_path = _discover_prepared_csv(prepared_root, kind)
    if not csv_path.exists():
        raise FileNotFoundError(csv_path)
    if csv_path.name != EXCEL_FIGURE_DATA_CSV:
        raise ValueError(f"plot.py only reads {EXCEL_FIGURE_DATA_CSV}: {csv_path}")
    return csv_path


def model_e2e_csv_path(
    *,
    explicit: str | None,
    prepared_root: Path,
    latency_dir: Path,
    model_key: str,
) -> Path:
    if explicit:
        csv_path = _prepared_csv_from_path(resolve_under_latency_dir(explicit, latency_dir, prefer_existing=True))
    else:
        csv_path = _discover_model_e2e_csv(prepared_root, model_key)
    if not csv_path.exists():
        raise FileNotFoundError(csv_path)
    if csv_path.name != EXCEL_FIGURE_DATA_CSV:
        raise ValueError(f"plot.py only reads {EXCEL_FIGURE_DATA_CSV}: {csv_path}")
    return csv_path


def _is_missing(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, float) and math.isnan(value):
        return True
    return False


def _ordered_unique(values: Sequence[Any]) -> list[Any]:
    out: list[Any] = []
    seen: set[str] = set()
    for value in values:
        if _is_missing(value):
            continue
        key = str(value)
        if key in seen:
            continue
        seen.add(key)
        out.append(value)
    return out


def _stage_sort_key(stage: Any) -> tuple[int, str]:
    text = str(stage)
    try:
        return (STAGE_ORDER.index(text), text)
    except ValueError:
        return (len(STAGE_ORDER), text)


def _seq_sort_key(seq: Any) -> int:
    text = str(seq).strip().lower()
    try:
        return int(text)
    except ValueError:
        pass
    if text.endswith("k"):
        try:
            return int(float(text[:-1]) * 1024)
        except ValueError:
            return 1 << 60
    return 1 << 60


def _format_batch(value: Any) -> str:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return str(value)
    if math.isfinite(numeric) and numeric.is_integer():
        return str(int(numeric))
    return str(value)


def _plot_size(knobs: WideBarKnobs, row_count: int) -> tuple[float, float]:
    row_height = knobs.row_height if knobs.row_height is not None else knobs.figsize[1]
    return (knobs.figsize[0], max(knobs.figsize[1], row_height * row_count))


def _palette(knobs: WideBarKnobs) -> tuple[str, ...]:
    return BAR_PALETTE if knobs.palette is None else knobs.palette


def _stack_palette(knobs: StackedBarKnobs) -> tuple[str, ...]:
    return GEMM_ONLY_STACK_PALETTE if knobs.stack_palette is None else knobs.stack_palette


def _plot_knobs_from_args(args: argparse.Namespace) -> PlotKnobs:
    knobs: PlotKnobs = copy.deepcopy(PLOT_KNOBS)
    plot_knobs: list[WideBarKnobs] = [knobs.main_all, knobs.gemm_only, knobs.energy, knobs.llama_e2e]

    for item in plot_knobs:
        if args.figure_width is not None:
            item.figsize = (float(args.figure_width), item.figsize[1])
        if args.row_height is not None:
            item.row_height = float(args.row_height)
        if args.x_label is not None:
            item.x_label = args.x_label
        if args.y_label is not None:
            item.y_label = args.y_label
        if args.legend_title is not None:
            item.legend_title = args.legend_title
        if args.legend_ncol is not None:
            item.legend_ncol = args.legend_ncol
        if args.subplot_title_template is not None:
            item.subplot_title_template = args.subplot_title_template
        if args.value_labels is not None:
            item.value_labels = bool(args.value_labels)
        item.x_group_axis = None if args.x_group_axis == "none" else args.x_group_axis
        item.x_group_gap = args.x_group_gap

    if args.title is not None:
        for item in plot_knobs:
            item.title = args.title

    return knobs


def _format_template(template: str, **values: Any) -> str:
    try:
        return template.format(**values)
    except KeyError as exc:
        missing = exc.args[0]
        valid = ", ".join(sorted(values))
        raise ValueError(f"unknown template field {{{missing}}}; valid fields: {valid}") from exc


def _display_label(axis: str | None, value: Any, options: Any) -> str:
    if axis is None or _is_missing(value):
        return ""
    for key, label in getattr(options, "label_maps", {}).get(axis, {}).items():
        if key == value or str(key) == str(value):
            return str(label)
    return str(value)


def _stack_display_label(value: Any, options: Any) -> str:
    axis = "stack_key" if "stack_key" in getattr(options, "label_maps", {}) else options.stack_by
    return _display_label(axis, value, options)


def _format_seq_for_excel(value: Any) -> str:
    try:
        seq = int(value)
    except (TypeError, ValueError):
        return "" if _is_missing(value) else str(value)
    if seq >= 1024 and seq % 1024 == 0:
        return f"{seq // 1024}k"
    return str(seq)


def _numeric_columns(pd: Any, df: Any, excluded: set[str]) -> list[str]:
    out: list[str] = []
    for column in df.columns:
        if column in excluded:
            continue
        values = pd.to_numeric(df[column], errors="coerce")
        if values.notna().any():
            out.append(column)
    return out


def _wide_value_columns(frame: Any, desired: Sequence[str]) -> list[str]:
    desired_present = [column for column in desired if column in frame.columns]
    extras = [column for column in frame.columns if column not in desired_present]
    return [*desired_present, *extras]


def _ensure_columns(frame: Any, columns: Sequence[str]) -> None:
    for column in columns:
        if column not in frame.columns:
            frame[column] = ""


def write_latency_figure_data_csv(deps: Any, result: Any) -> Path:
    """Write the compact latency table consumed by this plotting script."""
    options = result.options
    plot_mod = deps.latency_plot_module
    x, hue, row, col = plot_mod._validate_bar_axes(options)
    active_axes = tuple(axis for axis in (x, hue, row, col) if axis is not None)
    value_col = "relative_value"

    rows = plot_mod._aggregate_for_axes(result.plot_data, active_axes)
    rows[value_col] = rows["total_latency_us"]
    relative_group_axes = plot_mod._relative_group_axes(options.relative_scope, x, row, col)
    baselines = plot_mod._relative_baselines(rows, value_col, relative_group_axes)
    if options.relative:
        rows = plot_mod._apply_relative_values(rows, value_col, baselines, relative_group_axes)

    if options.stacked:
        export = plot_mod._aggregate_stack_for_axes(result.stack_data, active_axes)
        export[value_col] = export["total_latency_us"]
        if options.relative:
            export = plot_mod._apply_relative_values(export, value_col, baselines, relative_group_axes)
        export["candidate"] = export[hue].map(lambda value: _display_label(hue, value, options)) if hue else ""
        export["legend"] = export["stack_key"].map(lambda value: _stack_display_label(value, options))
        export["stage"] = export["stage"].map(lambda value: _display_label("stage", value, options)) if "stage" in export else ""
        export["seq"] = export["seq_len"].map(_format_seq_for_excel) if "seq_len" in export else ""
        export["seq_sort"] = export["seq_len"].map(_seq_sort_key) if "seq_len" in export else 0
        export = export.sort_values(["stage", "batch", "seq_sort", "candidate", "legend"])
        stack_columns = list(dict.fromkeys(export["legend"].dropna().astype(str)))
        wide = (
            export.pivot_table(
                index=["stage", "batch", "seq_sort", "seq", "candidate"],
                columns="legend",
                values=value_col,
                aggfunc="sum",
            )
            .reset_index()
            .rename_axis(None, axis=1)
            .sort_values(["stage", "batch", "seq_sort", "candidate"])
        )
        value_columns = _wide_value_columns(
            wide.drop(columns=["stage", "batch", "seq_sort", "seq", "candidate"]),
            stack_columns,
        )
        wide["total"] = wide[value_columns].sum(axis=1, skipna=True)
        wide = wide[["stage", "batch", "seq_sort", "seq", "candidate", *value_columns, "total"]]
        wide["batch"] = wide["batch"].astype(str)
        wide["seq"] = wide["seq"].astype(str)
        repeated_group = wide[["stage", "batch", "seq_sort"]].duplicated()
        wide.loc[repeated_group, ["batch", "seq"]] = ""
        export = wide.drop(columns=["seq_sort"])
        columns = list(export.columns)
    else:
        export = rows.copy()
        export["legend"] = export[hue].map(lambda value: _display_label(hue, value, options)) if hue else "total"
        export["stage"] = export["stage"].map(lambda value: _display_label("stage", value, options)) if "stage" in export else ""
        export["seq"] = export["seq_len"].map(_format_seq_for_excel) if "seq_len" in export else ""
        export["seq_sort"] = export["seq_len"].map(_seq_sort_key) if "seq_len" in export else 0
        export = export.sort_values(["stage", "batch", "seq_sort", "legend"])
        wide = (
            export.pivot_table(
                index=["stage", "batch", "seq_sort", "seq"],
                columns="legend",
                values=value_col,
                aggfunc="sum",
            )
            .reset_index()
            .rename_axis(None, axis=1)
            .sort_values(["stage", "batch", "seq_sort"])
        )
        _ensure_columns(wide, E2E_CANDIDATE_COLUMNS)
        export = wide[["stage", "batch", "seq", *E2E_CANDIDATE_COLUMNS]]
        columns = list(export.columns)

    path = result.out_dir / EXCEL_FIGURE_DATA_CSV
    path.parent.mkdir(parents=True, exist_ok=True)
    export[columns].to_csv(path, index=False)
    print(f"wrote {path}")
    return path


def write_energy_figure_data_csv(result: EnergyExcelResult, *, label_maps: dict[str, dict[Any, str]]) -> Path:
    """Write the compact energy table consumed by this plotting script."""
    summary = result.summary.copy()
    value_col = "relative_joules_per_token" if "relative_joules_per_token" in summary.columns else "joules_per_token"
    if value_col not in summary.columns:
        export = summary.iloc[0:0].copy()
    else:
        export = summary[summary[value_col].notna()].copy()

    class _Options:
        pass

    options = _Options()
    options.label_maps = label_maps
    export["stage"] = export["stage"].map(lambda value: _display_label("stage", value, options)) if "stage" in export else ""
    export["batch"] = export["batch"] if "batch" in export else ""
    export["seq"] = export["seq_len"].map(_format_seq_for_excel) if "seq_len" in export else ""
    export["seq_sort"] = export["seq_len"].map(_seq_sort_key) if "seq_len" in export else 0
    export["legend"] = export["variant"].map(lambda value: _display_label("variant", value, options)) if "variant" in export else ""
    export["relative_value"] = export[value_col].astype(float) if value_col in export else []
    export = export.sort_values(["stage", "batch", "seq_sort", "legend"])
    wide = (
        export.pivot_table(
            index=["stage", "batch", "seq_sort", "seq"],
            columns="legend",
            values="relative_value",
            aggfunc="sum",
        )
        .reset_index()
        .rename_axis(None, axis=1)
        .sort_values(["stage", "batch", "seq_sort"])
    )
    _ensure_columns(wide, E2E_CANDIDATE_COLUMNS)
    wide = wide[["stage", "batch", "seq", *E2E_CANDIDATE_COLUMNS]]

    path = result.figure_path.parent / EXCEL_FIGURE_DATA_CSV
    path.parent.mkdir(parents=True, exist_ok=True)
    wide.to_csv(path, index=False)
    print(f"wrote {path}")
    return path


def _read_excel_figure_data(path: Path) -> Any:
    pd, _ = _import_plot_modules()
    df = pd.read_csv(path)
    if "stage" in df.columns:
        for column in ("stage", "batch", "seq"):
            if column in df.columns:
                df[column] = df[column].replace("", pd.NA).ffill()
    return df


def _save_figure(fig: Any, path: Path, knobs: WideBarKnobs) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if knobs.save_png:
        fig.savefig(path, dpi=knobs.dpi, bbox_inches="tight")
        print(f"wrote {path}")
    if knobs.save_pdf:
        fig.savefig(path.with_suffix(".pdf"), bbox_inches="tight")
        print(f"wrote {path.with_suffix('.pdf')}")
    if knobs.save_svg:
        fig.savefig(path.with_suffix(".svg"), bbox_inches="tight")
        print(f"wrote {path.with_suffix('.svg')}")


def _x_label(row: Any, *, include_batch: bool) -> str:
    seq = str(row["seq"])
    if include_batch:
        return f"b{_format_batch(row['batch'])}\n{seq}"
    return seq


def _add_value_labels(ax: Any, bars: Any, knobs: WideBarKnobs) -> None:
    for bar in bars:
        height = bar.get_height()
        if not math.isfinite(float(height)) or abs(float(height)) < 1.0e-12:
            continue
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            height + knobs.value_label_dy,
            knobs.value_label_format.format(height),
            ha=knobs.value_label_ha,
            va=knobs.value_label_va,
            rotation=knobs.value_label_rotation,
            fontsize=knobs.value_label_fontsize,
        )


def _apply_y_limits(ax: Any, stage: Any, ymax: float, knobs: WideBarKnobs) -> None:
    stage_lim = knobs.stage_y_lims.get(str(stage))
    y_lim = stage_lim if stage_lim is not None else knobs.y_lim
    if y_lim is None:
        ax.set_ylim(0.0, max(ymax * knobs.y_lim_top_scale, 1.0))
        return
    bottom, top = y_lim
    if bottom is None:
        bottom = 0.0
    if top is None:
        top = max(ymax * knobs.y_lim_top_scale, 1.0)
    ax.set_ylim(bottom, top)


def _add_top_legend(fig: Any, handles: Any, labels: Any, value_count: int, knobs: WideBarKnobs) -> None:
    if knobs.legend_position == "none" or not handles:
        return
    if knobs.legend_position == "bottom":
        loc = knobs.legend_loc or "upper center"
        bbox = knobs.legend_bbox_to_anchor or (0.5, knobs.legend_y)
    else:
        loc = knobs.legend_loc or "upper center"
        bbox = knobs.legend_bbox_to_anchor or (0.5, knobs.legend_y)
    fig.legend(
        handles,
        labels,
        loc=loc,
        bbox_to_anchor=bbox,
        ncol=knobs.legend_ncol or min(value_count, LEGEND_NCOL),
        fontsize=knobs.legend_fontsize,
        title=knobs.legend_title,
        title_fontsize=knobs.legend_title_fontsize,
        frameon=False,
    )


def plot_wide_candidate_bars(
    csv_path: Path,
    out_dir: Path,
    *,
    filename: str,
    knobs: WideBarKnobs,
) -> None:
    pd, plt = _import_plot_modules()
    df = _read_excel_figure_data(csv_path)
    if df.empty:
        print(f"skip {knobs.title}: {csv_path} has no rows")
        return

    value_columns = [column for column in E2E_CANDIDATE_COLUMNS if column in df.columns]
    if not value_columns:
        raise ValueError(f"{csv_path} has no candidate value columns")
    for column in value_columns:
        df[column] = pd.to_numeric(df[column], errors="coerce")

    stages = sorted(_ordered_unique(df["stage"].tolist()), key=_stage_sort_key)
    fig, axes = plt.subplots(len(stages), 1, figsize=_plot_size(knobs, len(stages)), squeeze=False)
    axes_list = list(axes[:, 0])
    palette = _palette(knobs)
    colors = {column: palette[idx % len(palette)] for idx, column in enumerate(value_columns)}

    for ax, stage in zip(axes_list, stages):
        stage_df = df[df["stage"].astype(str).eq(str(stage))].copy()
        stage_df["__seq_sort"] = stage_df["seq"].map(_seq_sort_key)
        stage_df["__batch_sort"] = pd.to_numeric(stage_df["batch"], errors="coerce")
        stage_df = stage_df.sort_values(["__batch_sort", "__seq_sort", "seq"])

        include_batch = knobs.x_group_axis == "batch" and stage_df["batch"].nunique(dropna=True) > 1
        group_keys = list(zip(stage_df["batch"].astype(str), stage_df["seq"].astype(str)))
        positions: list[float] = []
        current = 0.0
        previous_batch: str | None = None
        for batch, _seq in group_keys:
            if previous_batch is not None and include_batch and batch != previous_batch:
                current += knobs.x_group_gap
            positions.append(current)
            current += 1.0
            previous_batch = batch

        width = min(knobs.bar_width, 0.78 / max(len(value_columns), 1))
        center_shift = width * (len(value_columns) - 1) / 2.0
        for idx, column in enumerate(value_columns):
            values = stage_df[column].fillna(0.0).tolist()
            x_values = [position + idx * width - center_shift for position in positions]
            bars = ax.bar(
                x_values,
                values,
                width=width,
                color=colors[column],
                edgecolor=knobs.bar_edgecolor,
                linewidth=knobs.bar_linewidth,
                alpha=knobs.bar_alpha,
                label=column,
            )
            if knobs.value_labels:
                _add_value_labels(ax, bars, knobs)

        ax.set_title(
            _format_template(knobs.subplot_title_template, stage=stage, model=""),
            fontsize=knobs.subplot_title_fontsize,
        )
        ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
        ax.set_xticks(positions)
        ax.set_xticklabels(
            [_x_label(row, include_batch=include_batch) for _, row in stage_df.iterrows()],
            fontsize=knobs.tick_label_fontsize,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max((float(value) for column in value_columns for value in stage_df[column].fillna(0.0)), default=1.0)
        _apply_y_limits(ax, stage, ymax, knobs)

    handles, labels = axes_list[0].get_legend_handles_labels()
    _add_top_legend(fig, handles, labels, len(value_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(rect=knobs.tight_layout_rect)
    _save_figure(fig, out_dir / filename, knobs)
    plt.close(fig)


def _gemm_stack_columns(pd: Any, df: Any) -> list[str]:
    excluded = {"stage", "batch", "seq", "candidate", "total"}
    columns = _numeric_columns(pd, df, excluded)
    return [column for column in columns if column != "total"]


def _gemm_row_label(row: Any, *, include_batch: bool) -> str:
    prefix = f"b{_format_batch(row['batch'])} " if include_batch else ""
    return f"{row['candidate']}\n{prefix}{row['seq']}"


def plot_gemm_stacked_bars(
    csv_path: Path,
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    pd, plt = _import_plot_modules()
    df = _read_excel_figure_data(csv_path)
    if df.empty:
        print(f"skip GEMM-only latency: {csv_path} has no rows")
        return
    required = {"stage", "batch", "seq", "candidate"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"{csv_path} missing columns: {sorted(missing)}")

    stack_columns = _gemm_stack_columns(pd, df)
    if not stack_columns:
        raise ValueError(f"{csv_path} has no GEMM stack value columns")
    for column in stack_columns:
        df[column] = pd.to_numeric(df[column], errors="coerce").fillna(0.0)

    stages = sorted(_ordered_unique(df["stage"].tolist()), key=_stage_sort_key)
    fig, axes = plt.subplots(len(stages), 1, figsize=_plot_size(knobs, len(stages)), squeeze=False)
    axes_list = list(axes[:, 0])
    palette = _stack_palette(knobs)
    colors = {column: palette[idx % len(palette)] for idx, column in enumerate(stack_columns)}
    candidate_order = {candidate: idx for idx, candidate in enumerate(E2E_CANDIDATE_COLUMNS)}

    for ax, stage in zip(axes_list, stages):
        stage_df = df[df["stage"].astype(str).eq(str(stage))].copy()
        stage_df["__seq_sort"] = stage_df["seq"].map(_seq_sort_key)
        stage_df["__batch_sort"] = pd.to_numeric(stage_df["batch"], errors="coerce")
        stage_df["__candidate_sort"] = stage_df["candidate"].map(lambda value: candidate_order.get(str(value), len(candidate_order)))
        stage_df = stage_df.sort_values(["__batch_sort", "__seq_sort", "__candidate_sort", "candidate"])

        include_batch = knobs.x_group_axis == "batch" and stage_df["batch"].nunique(dropna=True) > 1
        positions: list[float] = []
        current = 0.0
        previous_group: tuple[str, str] | None = None
        for _, row in stage_df.iterrows():
            group = (str(row["batch"]), str(row["seq"]))
            if previous_group is not None and group != previous_group:
                current += knobs.x_group_gap
            positions.append(current)
            current += 1.0
            previous_group = group

        bottoms = [0.0 for _ in positions]
        for column in stack_columns:
            values = stage_df[column].tolist()
            ax.bar(
                positions,
                values,
                bottom=bottoms,
                width=knobs.bar_width,
                color=colors[column],
                edgecolor=knobs.bar_edgecolor,
                linewidth=knobs.bar_linewidth,
                alpha=knobs.bar_alpha,
                label=column,
            )
            bottoms = [bottom + value for bottom, value in zip(bottoms, values)]

        ax.set_title(
            _format_template(knobs.subplot_title_template, stage=stage, model=""),
            fontsize=knobs.subplot_title_fontsize,
        )
        ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
        ax.set_xticks(positions)
        ax.set_xticklabels(
            [_gemm_row_label(row, include_batch=include_batch) for _, row in stage_df.iterrows()],
            fontsize=knobs.tick_label_fontsize,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max(bottoms, default=1.0)
        _apply_y_limits(ax, stage, ymax, knobs)

    handles, labels = axes_list[-1].get_legend_handles_labels()
    _add_top_legend(fig, handles, labels, len(stack_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(rect=knobs.tight_layout_rect)
    _save_figure(fig, out_dir / "gemm_only_latency.png", knobs)
    plt.close(fig)


def plot_llama_e2e_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    pd, plt = _import_plot_modules()
    frames = []
    for _model_key, model_label, csv_path in model_csvs:
        df = _read_excel_figure_data(csv_path)
        if df.empty:
            print(f"skip {model_label}: {csv_path} has no rows")
            continue
        df = df.copy()
        df["model"] = model_label
        frames.append(df)

    if not frames:
        print(f"skip {knobs.title}: no model rows")
        return

    combined = pd.concat(frames, ignore_index=True)
    value_columns = [column for column in E2E_CANDIDATE_COLUMNS if column in combined.columns]
    if not value_columns:
        raise ValueError("Llama E2E data has no candidate value columns")
    for column in value_columns:
        combined[column] = pd.to_numeric(combined[column], errors="coerce")

    row_specs = list(LLAMA_E2E_ROW_ORDER)
    fig, axes = plt.subplots(len(row_specs), 1, figsize=_plot_size(knobs, len(row_specs)), squeeze=False)
    axes_list = list(axes[:, 0])
    palette = _palette(knobs)
    colors = {column: palette[idx % len(palette)] for idx, column in enumerate(value_columns)}
    legend_handles = None
    legend_labels = None

    for ax, (model_label, stage) in zip(axes_list, row_specs):
        stage_df = combined[
            combined["model"].astype(str).eq(model_label)
            & combined["stage"].astype(str).eq(stage)
        ].copy()
        ax.set_title(
            _format_template(knobs.subplot_title_template, model=model_label, stage=stage),
            fontsize=knobs.subplot_title_fontsize,
        )
        if stage_df.empty:
            ax.text(
                0.5,
                0.5,
                "no data",
                transform=ax.transAxes,
                ha="center",
                va="center",
                fontsize=knobs.tick_label_fontsize,
            )
            ax.set_xticks([])
            ax.set_yticks([])
            continue

        stage_df["__seq_sort"] = stage_df["seq"].map(_seq_sort_key)
        stage_df["__batch_sort"] = pd.to_numeric(stage_df["batch"], errors="coerce")
        stage_df = stage_df.sort_values(["__batch_sort", "__seq_sort", "seq"])

        include_batch = knobs.x_group_axis == "batch" and stage_df["batch"].nunique(dropna=True) > 1
        group_keys = list(zip(stage_df["batch"].astype(str), stage_df["seq"].astype(str)))
        positions: list[float] = []
        current = 0.0
        previous_batch: str | None = None
        for batch, _seq in group_keys:
            if previous_batch is not None and include_batch and batch != previous_batch:
                current += knobs.x_group_gap
            positions.append(current)
            current += 1.0
            previous_batch = batch

        width = min(knobs.bar_width, 0.78 / max(len(value_columns), 1))
        center_shift = width * (len(value_columns) - 1) / 2.0
        for idx, column in enumerate(value_columns):
            values = stage_df[column].fillna(0.0).tolist()
            x_values = [position + idx * width - center_shift for position in positions]
            bars = ax.bar(
                x_values,
                values,
                width=width,
                color=colors[column],
                edgecolor=knobs.bar_edgecolor,
                linewidth=knobs.bar_linewidth,
                alpha=knobs.bar_alpha,
                label=column,
            )
            if knobs.value_labels:
                _add_value_labels(ax, bars, knobs)

        if legend_handles is None:
            legend_handles, legend_labels = ax.get_legend_handles_labels()
        ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
        ax.set_xticks(positions)
        ax.set_xticklabels(
            [_x_label(row, include_batch=include_batch) for _, row in stage_df.iterrows()],
            fontsize=knobs.tick_label_fontsize,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max((float(value) for column in value_columns for value in stage_df[column].fillna(0.0)), default=1.0)
        _apply_y_limits(ax, stage, ymax, knobs)

    _add_top_legend(fig, legend_handles, legend_labels, len(value_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(rect=knobs.tight_layout_rect)
    _save_figure(fig, out_dir / "llama_e2e_latency.png", knobs)
    plt.close(fig)


def run_main_all_plot(
    csv_path: Path,
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_wide_candidate_bars(
        csv_path,
        output_root / "main_all",
        filename="main_all_latency.png",
        knobs=knobs,
    )


def run_gemm_only_plot(
    csv_path: Path,
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_gemm_stacked_bars(
        csv_path,
        output_root / "main_all_gemm_only",
        knobs=knobs,
    )


def run_energy_plot(
    csv_path: Path,
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_wide_candidate_bars(
        csv_path,
        output_root / "energy_per_token",
        filename="energy_per_token.png",
        knobs=knobs,
    )


def run_llama_e2e_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_llama_e2e_bars(
        model_csvs,
        output_root / "llama_e2e",
        knobs=knobs,
    )


def run_selected_plots(args: argparse.Namespace) -> None:
    repo_root = find_repo_root()
    latency_dir = Path(args.latency_dir).expanduser().resolve() if args.latency_dir else repo_root / "analysis_workspace" / "latency_on_hw"
    prepared_root = resolve_under_latency_dir(args.prepared_root, latency_dir)
    output_root = resolve_under_latency_dir(args.out_dir, latency_dir)
    output_root.mkdir(parents=True, exist_ok=True)

    plot = args.plot
    knobs = _plot_knobs_from_args(args)

    if plot in {"main_all", "latency", "all"}:
        main_csv = prepared_csv_path(
            explicit=args.main_data,
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            kind="main_all",
        )
        run_main_all_plot(
            main_csv,
            output_root,
            knobs=knobs.main_all,
        )

    if plot in {"gemm_only", "latency", "all"}:
        gemm_csv = prepared_csv_path(
            explicit=args.gemm_data,
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            kind="gemm_only",
        )
        run_gemm_only_plot(
            gemm_csv,
            output_root,
            knobs=knobs.gemm_only,
        )

    if plot in {"energy", "all"}:
        energy_csv = prepared_csv_path(
            explicit=args.energy_data,
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            kind="energy",
        )
        run_energy_plot(
            energy_csv,
            output_root,
            knobs=knobs.energy,
        )

    if plot in {"llama_e2e", "all"}:
        required = plot == "llama_e2e" or bool(args.llama2_data) or bool(args.llama3_data)
        explicit_by_model = {
            "llama2_7b": args.llama2_data,
            "llama3_8b": args.llama3_data,
        }
        model_csvs: list[tuple[str, str, Path]] = []
        missing_error: Exception | None = None
        for model_key, model_label in LLAMA_E2E_MODELS:
            try:
                csv_path = model_e2e_csv_path(
                    explicit=explicit_by_model[model_key],
                    prepared_root=prepared_root,
                    latency_dir=latency_dir,
                    model_key=model_key,
                )
            except FileNotFoundError as exc:
                missing_error = exc
                break
            model_csvs.append((model_key, model_label, csv_path))

        if missing_error is not None:
            if required:
                raise missing_error
            print(f"skip llama_e2e: {missing_error}")
        else:
            run_llama_e2e_plot(
                model_csvs,
                output_root,
                knobs=knobs.llama_e2e,
            )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    run_selected_plots(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
