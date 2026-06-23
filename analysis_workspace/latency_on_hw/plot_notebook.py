#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


DEFAULT_OUT_DIR = "outputs_main/figures_script"
PLOT_CHOICES = ("main_all", "gemm_only", "energy", "layout_overhead", "latency", "all")

TWO_COLUMN_FIGSIZE = (7.16, 4.9)  # Matplotlib order: width, height in inches.
LAYOUT_OVERHEAD_FIGSIZE = (7.16, 3.2)
SAVE_DPI = 600

TITLE_FONTSIZE = 8.0
SUBPLOT_TITLE_FONTSIZE = 7.2
AXIS_LABEL_FONTSIZE = 6.6
TICK_LABEL_FONTSIZE = 6.2
LEGEND_FONTSIZE = 5.4
LEGEND_TITLE_FONTSIZE = 5.6

FPGA_IDLE_POWER = 0.854 * 6.300 + 0.852 * 0.200

RAW_DBS_OUTPUT_MAIN_REL = (
    "outputs_main/naive_simd/raw_db.csv",
    "outputs_main/naive_gemm_tcol32/raw_db.csv",
    "outputs_main/improve_tcol32/raw_db.csv",
    "outputs_main/improve_no_tcu_lut_fexp/raw_db.csv",
)
RAW_DBS_POWER_EXTRA_REL = (
    "outputs_main_power_long/naive_simd/raw_db.csv",
)
SUITE_FILE_ORDER = (
    "llama2_7b_prefill_C1.yaml",
    "llama2_7b_prefill_C2.yaml",
    "llama2_7b_prefill_C3.yaml",
    "llama2_7b_prefill_C4_alone.yaml",
    "llama2_7b_prefill_C4_fused.yaml",
    "llama2_7b_generation_C1.yaml",
    "llama2_7b_generation_C2.yaml",
    "llama2_7b_generation_C3.yaml",
    "llama2_7b_generation_C4_alone.yaml",
    "llama2_7b_generation_C4_fused.yaml",
)

METRIC = "p50_us"
SELECT = "latest"
MISSING = "nan"
X_AXIS = "seq_len"
HUE_AXIS = "variant"
ROW_AXIS = "stage"
COL_AXIS = "batch"
X_GROUP_AXIS = COL_AXIS
X_GROUP_GAP = 0.35
STACKED = True
STACK_BY = "name"
VALUE_LABELS = True
RELATIVE = True
RELATIVE_SCOPE = "x_tick"
SHARE_Y = False
SHARE_Y_SCOPE = "row"
SUBPLOT_WSPACE = 0.04
SUBPLOT_HSPACE = 0.52
SHARED_X_LABEL = True
SHARED_X_LABEL_Y = 0.06
BOTTOM_LEGEND_SHARED_X_LABEL_Y = 0.15

C4_ALONE_VARIANT = "all_fpint_gemm_improve_alone_layout_spinquant"
C4_FUSED_VARIANT = "all_fpint_gemm_improve_fused_layout_spinquant"

AXIS_LABEL_MAP = {
    "seq_len": "sequence length",
    "variant": "variant",
    "stage": "stage",
    "batch": "batch",
    "name": "kernel",
}
LABEL_MAPS = {
    "stage": {"prefill": "Prefill", "generation": "Generation"},
    "seq_len": {
        1024: "1k",
        2048: "2k",
        4096: "4k",
        8192: "8k",
        16384: "16k",
        32768: "32k",
    },
    "variant": {
        "all_fpint_gemm_improve_alone_layout_spinquant": "C4-alone",
        "all_fpint_gemm_improve_fused_layout_spinquant": "C4-fused",
        "all_fpint_gemm_naive_spinquant": "C3",
        "all_sgemm_tcu_spinquant": "C1",
        "attn_sgemm_tcu_fpint_gemm_naive_spinquant": "C2",
    },
    "name": {},
}
VALUE_ORDERS = {
    "variant": [
        "all_sgemm_tcu_spinquant",
        "attn_sgemm_tcu_fpint_gemm_naive_spinquant",
        "all_fpint_gemm_naive_spinquant",
        "all_fpint_gemm_improve_alone_layout_spinquant",
        "all_fpint_gemm_improve_fused_layout_spinquant",
    ],
}

FIGURE_TITLE = None
SUBPLOT_TITLE_TEMPLATE = "{row_axis_label}={row_value_label}, {col_axis_label}={col_value_label}"
X_GROUP_SUBPLOT_TITLE_TEMPLATE = "{row_axis_label}={row_value_label}"
X_LABEL = "sequence length"
Y_LABEL = None
LEGEND_TITLE = None
LEGEND_POSITION = "right"
LEGEND_NCOL = None
STACK_LEGEND_SCOPE = "hue"

BAR_PALETTE = (
    "#08306B",
    "#08519C",
    "#2171B5",
    "#4292C6",
    "#6BAED6",
    "#9ECAE1",
    "#C6DBEF",
    "#DEEBF7",
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
HUE_STACK_CMAPS = ("Blues", "Blues", "Blues", "Blues", "Blues")
STACK_CMAP_MIN = 0.02
STACK_CMAP_MAX = 0.98
BAR_EDGECOLOR = "white"
BAR_LINEWIDTH = 0.25
BAR_ALPHA = 1.0
GROUPED_BAR_GAP = 0.01
VALUE_LABEL_ROTATION = 90.0
VALUE_LABEL_FONTSIZE = 4.0
X_TICK_LABEL_MODE = "group"
X_TICK_LABEL_ROTATION = 0.0
X_TICK_LABEL_HA = "center"
Y_LIM_TOP_SCALE = 1.30

LAYOUT_FUSED_APP_MAP = {
    "eladd_layout_fused": "eladd",
    "elmul_layout_fused": "elmul",
    "head_concat_layout_fused": "head_concat",
    "kv_cache_quant_layout_fused_w4a16": "kv_cache_quant_w4a16",
    "rms_norm_layout_fused": "rmsnorm",
    "rope_layout_fused": "rope",
    "silu_layout_fused": "silu",
    "softmax_layout_fused": "softmax",
}
LAYOUT_SHAPE_DROP_KEYS = {
    "consumer",
    "layout_from",
    "layout_group",
    "layout_to",
    "producer",
    "qparam_layout_to",
    "scale_zp_layout_to",
    "weight_layout_to",
}


@dataclass(frozen=True)
class PlotDeps:
    latency_plot_module: Any
    LatencyScaleRule: Any
    LatencyEstimateOptions: Any
    SuiteBarPlotOptions: Any
    prepare_suite_bar_data_versions: Callable[..., Any]
    plot_suite_bar_grid: Callable[..., Any]
    write_suite_bar_data_csvs: Callable[..., Any]
    load_suite: Callable[..., Any]


@dataclass
class PlotRunResult:
    tag: str
    out_dir: Path
    suites: list[Any]
    options: Any
    versions: Any
    composed: Any
    plot_data: Any
    stack_data: Any


def find_repo_root(start: Path | None = None) -> Path:
    path = Path.cwd() if start is None else start
    for candidate in (path.resolve(), *path.resolve().parents):
        if (candidate / "tools" / "latency_bench").is_dir():
            return candidate
    raise RuntimeError("failed to find Vortex repository root")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the same latency/power figures as analysis_workspace/latency_on_hw/plot.ipynb.",
    )
    parser.add_argument(
        "--plot",
        choices=PLOT_CHOICES,
        default="all",
        help="plot to generate: main_all, gemm_only, energy, layout_overhead, latency, or all",
    )
    parser.add_argument(
        "--out-dir",
        default=DEFAULT_OUT_DIR,
        help="output root. Relative paths are resolved under analysis_workspace/latency_on_hw.",
    )
    parser.add_argument(
        "--latency-dir",
        default=None,
        help="latency workspace directory. Defaults to analysis_workspace/latency_on_hw under the repo root.",
    )
    parser.add_argument(
        "--idle-power-w",
        type=float,
        default=FPGA_IDLE_POWER,
        help=f"idle power used by the energy plot when idle power is subtracted (default: {FPGA_IDLE_POWER:.6g})",
    )
    parser.add_argument(
        "--include-idle-power",
        action="store_true",
        help="use raw measured power for energy instead of subtracting --idle-power-w",
    )
    parser.add_argument(
        "--x-group-axis",
        choices=("none", "batch"),
        default=X_GROUP_AXIS or "none",
        help="fold this axis into grouped x-axis regions instead of subplot columns",
    )
    parser.add_argument(
        "--x-group-gap",
        type=float,
        default=X_GROUP_GAP,
        help=f"gap between x-axis groups when --x-group-axis is enabled (default: {X_GROUP_GAP:g})",
    )
    return parser.parse_args(argv)


def load_deps(repo_root: Path) -> PlotDeps:
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))

    import tools.latency_bench.plot as latency_plot_module
    from tools.latency_bench.compose import LatencyScaleRule
    from tools.latency_bench.estimate import LatencyEstimateOptions
    from tools.latency_bench.plot import (
        SuiteBarPlotOptions,
        plot_suite_bar_grid,
        prepare_suite_bar_data_versions,
        write_suite_bar_data_csvs,
    )
    from tools.latency_bench.suite import load_suite

    return PlotDeps(
        latency_plot_module=latency_plot_module,
        LatencyScaleRule=LatencyScaleRule,
        LatencyEstimateOptions=LatencyEstimateOptions,
        SuiteBarPlotOptions=SuiteBarPlotOptions,
        prepare_suite_bar_data_versions=prepare_suite_bar_data_versions,
        plot_suite_bar_grid=plot_suite_bar_grid,
        write_suite_bar_data_csvs=write_suite_bar_data_csvs,
        load_suite=load_suite,
    )


def resolve_under_latency_dir(path: str | Path, latency_dir: Path) -> Path:
    resolved = Path(path).expanduser()
    if not resolved.is_absolute():
        resolved = latency_dir / resolved
    return resolved.resolve()


def raw_dbs_output_main(latency_dir: Path) -> tuple[Path, ...]:
    return tuple(latency_dir / rel for rel in RAW_DBS_OUTPUT_MAIN_REL)


def raw_dbs_power(latency_dir: Path) -> tuple[Path, ...]:
    return (*raw_dbs_output_main(latency_dir), *(latency_dir / rel for rel in RAW_DBS_POWER_EXTRA_REL))


def suite_paths(latency_dir: Path, tag: str) -> list[Path]:
    return [latency_dir / "suites" / tag / filename for filename in SUITE_FILE_ORDER]


def exclude_c4_alone(df: Any) -> Any:
    return df["variant"].ne(C4_ALONE_VARIANT)


def only_gemm(df: Any) -> Any:
    return df["kind"].eq("gemm")


def plot_label_maps(*, include_c4_alone: bool) -> dict[str, dict[Any, str]]:
    label_maps = {axis: dict(mapping) for axis, mapping in LABEL_MAPS.items()}
    if not include_c4_alone:
        label_maps["variant"][C4_FUSED_VARIANT] = "C4"
    return label_maps


def set_suite_bar_ylim_padding(deps: PlotDeps, scale: float = Y_LIM_TOP_SCALE) -> None:
    def _set_bar_ylim_with_padding(ax: Any, max_height: float) -> None:
        top = max(float(max_height), 1.0) * scale
        ax.set_ylim(0.0, top)

    deps.latency_plot_module._set_bar_ylim = _set_bar_ylim_with_padding


def latency_estimate_options(deps: PlotDeps) -> Any:
    return deps.LatencyEstimateOptions(
        model="auto_shape",
        min_train_rows=3,
        fallback="nearest_scale",
        warn_extrapolation=False,
    )


def case_latency_scale_rules(deps: PlotDeps) -> tuple[Any, ...]:
    return (
        deps.LatencyScaleRule(
            "C2_gemm_area_norm",
            {"kind": "gemm", "variant": "attn_sgemm_tcu_fpint_gemm_naive_spinquant"},
            2.29,
        ),
        deps.LatencyScaleRule(
            "C3_gemm_area_norm",
            {"kind": "gemm", "variant": "all_fpint_gemm_naive_spinquant"},
            1.29,
        ),
        deps.LatencyScaleRule(
            "C4_gemm_area_norm",
            {"kind": "gemm", "variant": (C4_ALONE_VARIANT, C4_FUSED_VARIANT)},
            1.29,
        ),
    )


def run_suite_plot(
    deps: PlotDeps,
    *,
    repo_root: Path,
    latency_dir: Path,
    output_root: Path,
    tag: str,
    out_name: str | None = None,
    figure_title: str | None = None,
    row_filters: tuple[Callable[[Any], Any], ...] | None = None,
    stacked: bool | None = None,
    include_c4_alone: bool = False,
    stack_legend_scope: str | None = None,
    legend_position: str | None = None,
    legend_ncol: int | None = None,
    legend_title: str | None = None,
    palette: tuple[str, ...] | None = None,
    x_group_axis: str | None = X_GROUP_AXIS,
    x_group_gap: float = X_GROUP_GAP,
    emit_outputs: bool = True,
) -> PlotRunResult:
    suites_in = suite_paths(latency_dir, tag)
    out_dir = output_root / (out_name or tag)
    raw_dbs = raw_dbs_output_main(latency_dir)
    missing_inputs = [path for path in [*suites_in, *raw_dbs] if not path.exists()]
    if missing_inputs:
        raise FileNotFoundError("missing plot inputs:\n" + "\n".join(str(path) for path in missing_inputs))

    stacked_value = STACKED if stacked is None else stacked
    default_legend_title = LEGEND_TITLE if LEGEND_TITLE is not None else ("kernel" if stacked_value else "variant")
    effective_legend_title = default_legend_title if legend_title is None else legend_title
    plot_row_filters = tuple(() if row_filters is None else row_filters)
    if not include_c4_alone and exclude_c4_alone not in plot_row_filters:
        plot_row_filters = (*plot_row_filters, exclude_c4_alone)
    effective_stack_legend_scope = STACK_LEGEND_SCOPE if stack_legend_scope is None else stack_legend_scope
    effective_legend_position = LEGEND_POSITION if legend_position is None else legend_position
    shared_x_label_y = (
        BOTTOM_LEGEND_SHARED_X_LABEL_Y
        if effective_legend_position == "bottom"
        else SHARED_X_LABEL_Y
    )

    suites = [deps.load_suite(path, repo_root=repo_root) for path in suites_in]
    options = deps.SuiteBarPlotOptions(
        raw_dbs=raw_dbs,
        out_dir=out_dir,
        metric=METRIC,
        select=SELECT,
        missing=MISSING,
        x=X_AXIS,
        hue=HUE_AXIS,
        row=ROW_AXIS,
        col=COL_AXIS,
        stacked=stacked_value,
        stack_by=STACK_BY,
        value_labels=VALUE_LABELS,
        relative=RELATIVE,
        relative_scope=RELATIVE_SCOPE,
        share_y=SHARE_Y,
        share_y_scope=SHARE_Y_SCOPE,
        legend_position=effective_legend_position,
        legend_ncol=LEGEND_NCOL if legend_ncol is None else legend_ncol,
        figure_title=figure_title if figure_title is not None else FIGURE_TITLE,
        subplot_title_template=X_GROUP_SUBPLOT_TITLE_TEMPLATE if x_group_axis else SUBPLOT_TITLE_TEMPLATE,
        x_label=X_LABEL,
        y_label=Y_LABEL,
        legend_title=effective_legend_title,
        axis_label_map=AXIS_LABEL_MAP,
        label_maps=plot_label_maps(include_c4_alone=include_c4_alone),
        value_orders=VALUE_ORDERS,
        stack_legend_scope=effective_stack_legend_scope,
        latency_scale_rules=(),
        case_latency_scale_rules=case_latency_scale_rules(deps),
        latency_estimate=latency_estimate_options(deps),
        row_filters=plot_row_filters,
        palette=BAR_PALETTE if palette is None else palette,
        hue_stack_cmaps=HUE_STACK_CMAPS,
        stack_cmap_min=STACK_CMAP_MIN,
        stack_cmap_max=STACK_CMAP_MAX,
        bar_edgecolor=BAR_EDGECOLOR,
        bar_linewidth=BAR_LINEWIDTH,
        bar_alpha=BAR_ALPHA,
        grouped_bar_gap=GROUPED_BAR_GAP,
        value_label_rotation=VALUE_LABEL_ROTATION,
        value_label_fontsize=VALUE_LABEL_FONTSIZE,
        x_tick_label_mode=X_TICK_LABEL_MODE,
        x_tick_label_rotation=X_TICK_LABEL_ROTATION,
        x_tick_label_ha=X_TICK_LABEL_HA,
        figure_size=TWO_COLUMN_FIGSIZE,
        save_dpi=SAVE_DPI,
        figure_title_fontsize=TITLE_FONTSIZE,
        subplot_title_fontsize=SUBPLOT_TITLE_FONTSIZE,
        axis_label_fontsize=AXIS_LABEL_FONTSIZE,
        tick_label_fontsize=TICK_LABEL_FONTSIZE,
        legend_fontsize=LEGEND_FONTSIZE,
        legend_title_fontsize=LEGEND_TITLE_FONTSIZE,
        subplot_wspace=SUBPLOT_WSPACE,
        subplot_hspace=SUBPLOT_HSPACE,
        shared_x_label=SHARED_X_LABEL,
        shared_x_label_y=shared_x_label_y,
        x_group_axis=x_group_axis,
        x_group_gap=x_group_gap,
    )

    versions = deps.prepare_suite_bar_data_versions(suites, options)
    plot_input = versions.final
    if emit_outputs:
        for suffix, data in versions.csv_items():
            deps.write_suite_bar_data_csvs(data, out_dir, suffix=suffix)
        deps.plot_suite_bar_grid(plot_input.plot_data, plot_input.stack_data, options)
        print(f"wrote {out_dir}")

    return PlotRunResult(
        tag=tag,
        out_dir=out_dir,
        suites=suites,
        options=options,
        versions=versions,
        composed=plot_input.composed,
        plot_data=plot_input.plot_data,
        stack_data=plot_input.stack_data,
    )


def run_main_all_plot(
    deps: PlotDeps,
    *,
    repo_root: Path,
    latency_dir: Path,
    output_root: Path,
    x_group_axis: str | None = X_GROUP_AXIS,
    x_group_gap: float = X_GROUP_GAP,
    emit_outputs: bool = True,
) -> PlotRunResult:
    return run_suite_plot(
        deps,
        repo_root=repo_root,
        latency_dir=latency_dir,
        output_root=output_root,
        tag="main_all",
        out_name="main_all",
        figure_title="E2E latency (Area normalized)",
        stacked=False,
        include_c4_alone=False,
        legend_position="title_right",
        legend_ncol=4,
        legend_title="candidates",
        x_group_axis=x_group_axis,
        x_group_gap=x_group_gap,
        emit_outputs=emit_outputs,
    )


def run_gemm_only_plot(
    deps: PlotDeps,
    *,
    repo_root: Path,
    latency_dir: Path,
    output_root: Path,
    x_group_axis: str | None = X_GROUP_AXIS,
    x_group_gap: float = X_GROUP_GAP,
) -> PlotRunResult:
    return run_suite_plot(
        deps,
        repo_root=repo_root,
        latency_dir=latency_dir,
        output_root=output_root,
        tag="main_all",
        out_name="main_all_gemm_only",
        figure_title="GEMM Latency (Area normalized)",
        row_filters=(only_gemm, exclude_c4_alone),
        stacked=True,
        include_c4_alone=False,
        stack_legend_scope="global",
        palette=GEMM_ONLY_STACK_PALETTE,
        legend_position="bottom",
        legend_ncol=9,
        x_group_axis=x_group_axis,
        x_group_gap=x_group_gap,
    )


def run_energy_plot(
    *,
    latency_dir: Path,
    output_root: Path,
    main_all_result: PlotRunResult,
    idle_power_w: float,
    include_idle_power: bool,
    x_group_axis: str | None = X_GROUP_AXIS,
    x_group_gap: float = X_GROUP_GAP,
) -> Any:
    if str(latency_dir) not in sys.path:
        sys.path.insert(0, str(latency_dir))
    from energy_per_token import plot_energy_per_token

    raw_dbs = raw_dbs_power(latency_dir)
    missing_inputs = [path for path in raw_dbs if not path.exists()]
    if missing_inputs:
        raise FileNotFoundError("missing energy plot inputs:\n" + "\n".join(str(path) for path in missing_inputs))

    result = plot_energy_per_token(
        main_all_result,
        raw_dbs=raw_dbs,
        out_dir=output_root / "energy_per_token",
        idle_power_w=idle_power_w,
        include_idle_power=include_idle_power,
        title="E2E energy per token",
        label_maps=plot_label_maps(include_c4_alone=False),
        value_orders=VALUE_ORDERS,
        palette=BAR_PALETTE,
        legend_title="candidates",
        legend_position="top_right",
        relative=RELATIVE,
        relative_scope=RELATIVE_SCOPE,
        value_labels=VALUE_LABELS,
        value_label_rotation=VALUE_LABEL_ROTATION,
        value_label_fontsize=VALUE_LABEL_FONTSIZE,
        grouped_bar_gap=GROUPED_BAR_GAP,
        bar_edgecolor=BAR_EDGECOLOR,
        bar_linewidth=BAR_LINEWIDTH,
        bar_alpha=BAR_ALPHA,
        x_tick_label_rotation=X_TICK_LABEL_ROTATION,
        x_tick_label_ha=X_TICK_LABEL_HA,
        ylim_top_scale=Y_LIM_TOP_SCALE,
        figure_size=TWO_COLUMN_FIGSIZE,
        save_dpi=SAVE_DPI,
        title_fontsize=TITLE_FONTSIZE,
        subplot_title_fontsize=SUBPLOT_TITLE_FONTSIZE,
        axis_label_fontsize=AXIS_LABEL_FONTSIZE,
        tick_label_fontsize=TICK_LABEL_FONTSIZE,
        legend_fontsize=LEGEND_FONTSIZE,
        legend_title_fontsize=LEGEND_TITLE_FONTSIZE,
        share_y_scope=SHARE_Y_SCOPE,
        subplot_wspace=SUBPLOT_WSPACE,
        subplot_hspace=SUBPLOT_HSPACE,
        shared_x_label=SHARED_X_LABEL,
        shared_x_label_y=SHARED_X_LABEL_Y,
        x_group_axis=x_group_axis,
        x_group_gap=x_group_gap,
    )
    print(f"wrote {result.figure_path}")
    if result.figure_svg_path is not None:
        print(f"wrote {result.figure_svg_path}")
    print(f"wrote {result.summary_csv}")
    print(f"wrote {result.rows_csv}")
    return result


def _import_layout_modules() -> tuple[Any, Any]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import pandas as pd

    return pd, plt


def _parse_shape_json(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    if not isinstance(value, str) or not value.strip():
        return {}
    return json.loads(value)


def _canonical_layout_app(app: str) -> str:
    app = str(app)
    if app in LAYOUT_FUSED_APP_MAP:
        return LAYOUT_FUSED_APP_MAP[app]
    if app.endswith("_layout_fused"):
        return app[: -len("_layout_fused")]
    return app


def _layout_mode(app: str) -> str:
    app = str(app)
    return "layout_fused" if app in LAYOUT_FUSED_APP_MAP or app.endswith("_layout_fused") else "baseline"


def _canonical_shape(shape: Mapping[str, Any]) -> dict[str, Any]:
    out = {k: v for k, v in shape.items() if k not in LAYOUT_SHAPE_DROP_KEYS}
    if {"batch", "seq", "hidden", "M", "K"}.issubset(out):
        if out.get("M") == out.get("batch") * out.get("seq"):
            out.pop("M", None)
        if out.get("K") == out.get("hidden"):
            out.pop("K", None)
    if {"size", "M", "K"}.issubset(out):
        if out.get("size") == out.get("M") * out.get("K"):
            out.pop("M", None)
            out.pop("K", None)
    return dict(sorted(out.items(), key=lambda item: item[0]))


def _canonical_shape_json(shape: Mapping[str, Any]) -> str:
    return json.dumps(_canonical_shape(shape), sort_keys=True, separators=(",", ":"))


def load_layout_overhead_rows(raw_dbs: Sequence[Path], metric: str = METRIC) -> Any:
    pd, _ = _import_layout_modules()
    frames = []
    for raw_db in raw_dbs:
        df = pd.read_csv(raw_db)
        df["raw_db"] = str(raw_db)
        frames.append(df)
    raw = pd.concat(frames, ignore_index=True)
    raw = raw[(raw["status"].astype(str) == "pass") & pd.to_numeric(raw[metric], errors="coerce").notna()].copy()
    raw[metric] = pd.to_numeric(raw[metric], errors="coerce")
    raw["layout_mode"] = raw["app"].map(_layout_mode)
    raw["canonical_app"] = raw["app"].map(_canonical_layout_app)
    raw = raw[raw["layout_mode"].isin({"baseline", "layout_fused"})].copy()
    raw["shape_dict"] = raw["shape_json"].map(_parse_shape_json)
    raw["canonical_shape_dict"] = raw["shape_dict"].map(_canonical_shape)
    raw["canonical_shape_json"] = raw["shape_dict"].map(_canonical_shape_json)
    raw["latency_us"] = raw[metric]

    key_cols = ["fpga_bin_label", "canonical_app", "name", "canonical_shape_json"]
    baseline = raw[raw["layout_mode"] == "baseline"].copy()
    fused = raw[raw["layout_mode"] == "layout_fused"].copy()
    baseline = baseline.sort_values("timestamp_utc").drop_duplicates(key_cols, keep="last")
    fused = fused.sort_values("timestamp_utc").drop_duplicates(key_cols, keep="last")

    cols = [
        *key_cols,
        "app",
        "args",
        "shape_json",
        "canonical_shape_dict",
        "latency_us",
        "run_id",
        "case_id",
        "raw_db",
    ]
    pairs = baseline[cols].merge(
        fused[cols],
        on=key_cols,
        how="inner",
        suffixes=("_baseline", "_layout_fused"),
    )
    pairs = pairs.rename(
        columns={
            "app_baseline": "baseline_app",
            "args_baseline": "baseline_args",
            "shape_json_baseline": "baseline_shape_json",
            "latency_us_baseline": "baseline_us",
            "run_id_baseline": "baseline_run_id",
            "case_id_baseline": "baseline_case_id",
            "raw_db_baseline": "baseline_raw_db",
            "app_layout_fused": "layout_fused_app",
            "args_layout_fused": "layout_fused_args",
            "shape_json_layout_fused": "layout_fused_shape_json",
            "latency_us_layout_fused": "layout_fused_us",
            "run_id_layout_fused": "layout_fused_run_id",
            "case_id_layout_fused": "layout_fused_case_id",
            "raw_db_layout_fused": "layout_fused_raw_db",
        }
    )
    if pairs.empty:
        return pairs
    pairs["overhead_us"] = pairs["layout_fused_us"] - pairs["baseline_us"]
    pairs["overhead_pct"] = 100.0 * pairs["overhead_us"] / pairs["baseline_us"]
    pairs["layout_fused_over_baseline"] = pairs["layout_fused_us"] / pairs["baseline_us"]
    pairs["logical_shape"] = pairs["canonical_shape_dict_baseline"].map(lambda x: json.dumps(x, sort_keys=True))
    return pairs.sort_values(["canonical_app", "name", "logical_shape"]).reset_index(drop=True)


def summarize_layout_overhead(overhead: Any) -> Any:
    if overhead.empty:
        return overhead
    return (
        overhead.groupby(["fpga_bin_label", "canonical_app", "baseline_app", "layout_fused_app"], dropna=False)
        .agg(
            pairs=("overhead_us", "size"),
            baseline_us_median=("baseline_us", "median"),
            layout_fused_us_median=("layout_fused_us", "median"),
            overhead_us_median=("overhead_us", "median"),
            overhead_pct_median=("overhead_pct", "median"),
            overhead_pct_mean=("overhead_pct", "mean"),
            overhead_pct_min=("overhead_pct", "min"),
            overhead_pct_max=("overhead_pct", "max"),
            ratio_median=("layout_fused_over_baseline", "median"),
        )
        .reset_index()
        .sort_values(["overhead_pct_median", "canonical_app"], ascending=[False, True])
    )


def run_layout_overhead_plot(*, latency_dir: Path, output_root: Path) -> None:
    _, plt = _import_layout_modules()
    raw_dbs = raw_dbs_output_main(latency_dir)
    missing_inputs = [path for path in raw_dbs if not path.exists()]
    if missing_inputs:
        raise FileNotFoundError("missing layout-overhead inputs:\n" + "\n".join(str(path) for path in missing_inputs))

    out_dir = output_root / "layout_transform_overhead"
    out_dir.mkdir(parents=True, exist_ok=True)
    layout_overhead = load_layout_overhead_rows(raw_dbs)
    layout_overhead_summary = summarize_layout_overhead(layout_overhead)

    layout_overhead_csv = out_dir / "layout_transform_overhead.csv"
    layout_overhead_summary_csv = out_dir / "layout_transform_overhead_summary.csv"
    layout_overhead.to_csv(layout_overhead_csv, index=False)
    layout_overhead_summary.to_csv(layout_overhead_summary_csv, index=False)

    print(f"matched baseline/layout_fused pairs: {len(layout_overhead)}")
    print(f"wrote {layout_overhead_csv}")
    print(f"wrote {layout_overhead_summary_csv}")

    if layout_overhead_summary.empty:
        return

    plot_df = layout_overhead_summary.sort_values("overhead_pct_median", ascending=True)
    layout_height = max(LAYOUT_OVERHEAD_FIGSIZE[1], 0.32 * len(plot_df) + 0.8)
    fig, ax = plt.subplots(figsize=(LAYOUT_OVERHEAD_FIGSIZE[0], layout_height))
    labels = plot_df["canonical_app"] + "\n" + plot_df["layout_fused_app"]
    bars = ax.barh(labels, plot_df["overhead_pct_median"], color="#087E8B")
    ax.axvline(0, color="#333333", linewidth=0.8)
    ax.set_xlabel("median overhead vs baseline (%)", fontsize=AXIS_LABEL_FONTSIZE)
    ax.set_title("Layout fused overhead by canonical app", fontsize=TITLE_FONTSIZE)
    ax.tick_params(axis="both", labelsize=TICK_LABEL_FONTSIZE)
    ax.grid(axis="x", alpha=0.25)
    for bar, value in zip(bars, plot_df["overhead_pct_median"]):
        x = bar.get_width()
        ha = "left" if x >= 0 else "right"
        dx = 1.0 if x >= 0 else -1.0
        ax.text(
            x + dx,
            bar.get_y() + bar.get_height() / 2,
            f"{value:.1f}%",
            va="center",
            ha=ha,
            fontsize=VALUE_LABEL_FONTSIZE,
        )
    fig.tight_layout()
    fig_path = out_dir / "layout_transform_overhead_median_pct.png"
    fig.savefig(fig_path, dpi=SAVE_DPI, bbox_inches="tight")
    fig.savefig(fig_path.with_suffix(".pdf"), bbox_inches="tight")
    fig.savefig(fig_path.with_suffix(".svg"), bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {fig_path}")
    print(f"wrote {fig_path.with_suffix('.pdf')}")
    print(f"wrote {fig_path.with_suffix('.svg')}")


def run_selected_plots(args: argparse.Namespace) -> None:
    repo_root = find_repo_root()
    latency_dir = Path(args.latency_dir).expanduser().resolve() if args.latency_dir else repo_root / "analysis_workspace" / "latency_on_hw"
    output_root = resolve_under_latency_dir(args.out_dir, latency_dir)
    output_root.mkdir(parents=True, exist_ok=True)

    deps = load_deps(repo_root)
    set_suite_bar_ylim_padding(deps)

    plot = args.plot
    x_group_axis = None if args.x_group_axis == "none" else args.x_group_axis
    main_all_result: PlotRunResult | None = None

    if plot in {"main_all", "latency", "all"}:
        main_all_result = run_main_all_plot(
            deps,
            repo_root=repo_root,
            latency_dir=latency_dir,
            output_root=output_root,
            x_group_axis=x_group_axis,
            x_group_gap=args.x_group_gap,
        )

    if plot in {"gemm_only", "latency", "all"}:
        run_gemm_only_plot(
            deps,
            repo_root=repo_root,
            latency_dir=latency_dir,
            output_root=output_root,
            x_group_axis=x_group_axis,
            x_group_gap=args.x_group_gap,
        )

    if plot in {"energy", "all"}:
        if main_all_result is None:
            main_all_result = run_main_all_plot(
                deps,
                repo_root=repo_root,
                latency_dir=latency_dir,
                output_root=output_root,
                x_group_axis=x_group_axis,
                x_group_gap=args.x_group_gap,
                emit_outputs=False,
            )
        run_energy_plot(
            latency_dir=latency_dir,
            output_root=output_root,
            main_all_result=main_all_result,
            idle_power_w=args.idle_power_w,
            include_idle_power=args.include_idle_power,
            x_group_axis=x_group_axis,
            x_group_gap=args.x_group_gap,
        )

    # we don't need layout overhead plot
    # if plot in {"layout_overhead", "all"}:
    #     run_layout_overhead_plot(latency_dir=latency_dir, output_root=output_root)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    run_selected_plots(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
