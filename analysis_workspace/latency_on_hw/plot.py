#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import csv
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal, Sequence


DEFAULT_OUT_BASE = "output_figure"
DEFAULT_PREPARED_ROOT = f"{DEFAULT_OUT_BASE}/figures_prepare"
DEFAULT_OUT_DIR = f"{DEFAULT_OUT_BASE}/figures_script"
PLOT_CHOICES = (
    "main_all",
    "gemm_only",
    "energy",
    "llama_e2e",
    "llama_e2e_no_area_norm",
    "llama_e2e_no_area_norm_stacked",
    "llama_e2e_gemm_layout_stacked",
    "llama_e2e_gemm_layout_vector_stacked",
    "llama_e2e_stacked",
    "llama_gemm_only",
    "llama_gemm_only_no_area_norm",
    "llama_gemm_only_energy",
    "llama_gemm_only_energy_no_area_norm",
    "llama_energy",
    "llama_energy_no_area_norm",
    "llama_energy_stacked",
    "llama_energy_no_area_norm_stacked",
    "llama_energy_gemm_layout_vector_stacked",
    "llama_energy_no_area_norm_gemm_layout_vector_stacked",
    "kernel_dynamic_power",
    "latency",
    "all",
)
EXCEL_FIGURE_DATA_CSV = "excel_figure_data.csv"

ONE_COLUMN_FIGSIZE = (3.5, 9.3)
TWO_COLUMN_FIGSIZE = (7.16, 9.3)
GEMM_FIGSIZE = (3.5, 4.0)
LLAMA_GEMM_FIGSIZE = (3.5, 4.0)
LLAMA_E2E_STACKED_FIGSIZE = (3.5, 4.0)
KERNEL_DYNAMIC_POWER_FIGSIZE = (ONE_COLUMN_FIGSIZE[0], 2.5)
SAVE_DPI = 600
BAR_EDGECOLOR = "white"
BAR_LINEWIDTH = 0.25
BAR_ALPHA = 1.0

FIGURE_TITLE = None
MAIN_ALL_TITLE = "E2E latency"
GEMM_ONLY_TITLE = "GEMM latency breakdown"
ENERGY_TITLE = "E2E energy per token"
LLAMA_E2E_STACKED_TITLE = "Llama E2E latency breakdown"
LLAMA_GEMM_ONLY_TITLE = "Llama GEMM latency breakdown"
LLAMA_ENERGY_TITLE = "Llama energy per token"
SUBPLOT_TITLE_TEMPLATE = "{stage}"
LLAMA_E2E_SUBPLOT_TITLE_TEMPLATE = "{model}, {stage}"
X_LABEL = "sequence length"
Y_LABEL = "relative latency"
ENERGY_Y_LABEL = "relative energy"
LEGEND_TITLE = "candidate"
LEGEND_NCOL = 4
GEMM_LEGEND_TITLE = "kernel"

MIN_FONT_SIZE = 4.0
TITLE_FONTSIZE = MIN_FONT_SIZE+1
SUBPLOT_TITLE_FONTSIZE = MIN_FONT_SIZE+0.2
AXIS_LABEL_FONTSIZE = MIN_FONT_SIZE
TICK_LABEL_FONTSIZE = MIN_FONT_SIZE
LEGEND_TITLE_FONTSIZE = MIN_FONT_SIZE+0.2
LEGEND_FONTSIZE = MIN_FONT_SIZE
VALUE_LABEL_FONTSIZE: float | Literal["auto"] = "auto"
VALUE_LABEL_AUTO_MAX_FONTSIZE = MIN_FONT_SIZE
VALUE_LABEL_AUTO_WIDTH_SCALE = 0.92
# Small data-unit gap for labels that remain above a bar.
VALUE_LABEL_DY = 0.03
STACKED_LABEL_EDGE_PADDING_PX = 1.0

X_GROUP_AXIS = "batch"
X_GROUP_GAP = 0.35
SUBPLOT_X_MARGIN = 0.01
DECODE_BAR_WIDTH_SCALE = 1.20
MAX_BAR_FILL_RATIO = 0.96
VALUE_LABELS = True
E2E_CANDIDATE_COLUMNS = ("C1", "C2", "C3", "C4")
ENERGY_POWER_METRICS = ("power_avg_W", "power_vcc_avg_W", "power_dynamic_avg_W")
STAGE_ORDER = ("Prefill", "Decode")
RAW_DB_SUBDIRS = ("C1", "C3", "C4")
RAW_DB_ROOT_NAMES = (
    "outputs_llama2_main",
    "outputs_llama3_main",
    "outputs_llama3p2_1b_main",
    "outputs_llama3p2_3b_main",
)
GEMM_DYNAMIC_POWER_LABELS = {
    "sgemm_tcu": "FP-FP gemm",
    "fpint_gemm_ffn_hw_naive": "FP-INT naive gemm",
    "fpint_gemm_ffn_hw": "FP-INT gemm",
}
KERNEL_DYNAMIC_POWER_LABELS = {
    "quantization": "quant",
    "dequantization": "dequant",
}

# Models included in the combined Llama plots, in display order.
# TARGET_MODELS = [
#     "llama2_7b",
#     "llama3_8b",
#     "llama3p2_1b",
#     "llama3p2_3b",
# ]
TARGET_MODELS = [
    "llama2_7b",
    "llama3_8b",
]
LLAMA_MODEL_LABELS = {
    "llama2_7b": "Llama 2",
    "llama3_8b": "Llama 3",
    "llama3p2_1b": "Llama 3.2 1B",
    "llama3p2_3b": "Llama 3.2 3B",
}
_unknown_target_models = set(TARGET_MODELS) - set(LLAMA_MODEL_LABELS)
if _unknown_target_models:
    raise ValueError(f"unknown TARGET_MODELS: {sorted(_unknown_target_models)}")
if not TARGET_MODELS:
    raise ValueError("TARGET_MODELS must contain at least one model")
if len(set(TARGET_MODELS)) != len(TARGET_MODELS):
    raise ValueError("TARGET_MODELS must not contain duplicate models")

LLAMA_E2E_MODELS = tuple(
    (model_key, LLAMA_MODEL_LABELS[model_key])
    for model_key in TARGET_MODELS
)
LLAMA_E2E_ROW_ORDER = tuple(
    (model_label, stage)
    for _model_key, model_label in LLAMA_E2E_MODELS
    for stage in STAGE_ORDER
)

BAR_PALETTE = (
    "#08306B",
    "#2171B5",
    "#6BAED6",
    "#74C476",
    "#F28E2B",
    "#E15759",
)
STACK_PALETTE = (
    "#08306B",
    "#2171B5",
    "#6BAED6",
    "#00441B",
    "#238B45",
    "#74C476",
    "#4D4D4D",
    "#7F7F7F",
    "#BDBDBD",
)
GEMM_ONLY_STACK_PALETTE = STACK_PALETTE


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
    subplot_title_inside: bool = False
    subplot_title_replacements: tuple[tuple[str, str], ...] = ()
    axis_label_fontsize: float = AXIS_LABEL_FONTSIZE
    tick_label_fontsize: float = TICK_LABEL_FONTSIZE
    legend_fontsize: float = LEGEND_FONTSIZE
    legend_title_fontsize: float = LEGEND_TITLE_FONTSIZE
    bar_width: float = 0.18
    stage_bar_width_scales: dict[str, float] = field(
        default_factory=lambda: {"Decode": DECODE_BAR_WIDTH_SCALE}
    )
    bar_edgecolor: str = BAR_EDGECOLOR
    bar_linewidth: float = BAR_LINEWIDTH
    bar_alpha: float = BAR_ALPHA
    palette: tuple[str, ...] | None = None
    value_labels: bool = VALUE_LABELS
    value_label_format: str = "{:.2g}"
    value_label_fontsize: float | Literal["auto"] = VALUE_LABEL_FONTSIZE
    value_label_auto_max_fontsize: float = VALUE_LABEL_AUTO_MAX_FONTSIZE
    value_label_rotation: float = 90.0
    value_label_ha: str = "center"
    value_label_va: str = "bottom"
    value_label_dy: float = VALUE_LABEL_DY
    x_tick_label_rotation: float = 0.0
    stage_x_tick_label_rotations: dict[str, float] = field(default_factory=dict)
    x_group_axis: str | None = X_GROUP_AXIS
    x_group_gap: float = X_GROUP_GAP
    subplot_x_margin: float = SUBPLOT_X_MARGIN
    x_group_labels_inside: bool = False
    x_group_label_y: float = 0.98
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
    tight_layout_pad: float = 1.08
    tight_layout_h_pad: float | None = None
    save_png: bool = True
    save_pdf: bool = True
    save_svg: bool = True


@dataclass(frozen=True)
class StackGroupKnobs:
    label: str
    columns: tuple[str, ...] | None


GEMM_ONLY_STACK_GROUPS = (
    StackGroupKnobs(
        label="linear-qkvo",
        columns=("q_proj", "k_proj", "v_proj", "o_proj"),
    ),
    StackGroupKnobs(
        label="attn",
        columns=("attn_qkT", "attn_pv"),
    ),
    StackGroupKnobs(
        label="linear-ffn",
        columns=("down_proj", "gate_proj", "up_proj"),
    ),
)
GEMM_ONLY_GROUP_PALETTE = STACK_PALETTE[:3]
E2E_KIND_STACK_PALETTE = STACK_PALETTE
E2E_KIND_STACK_GROUPS = (
    StackGroupKnobs(label="gemm", columns=("gemm",)),
    StackGroupKnobs(label="vector", columns=None),
)
E2E_GEMM_LAYOUT_STACK_PALETTE = STACK_PALETTE
E2E_GEMM_LAYOUT_VECTOR_STACK_PALETTE = STACK_PALETTE
E2E_GEMM_LAYOUT_VECTOR_DEQUANT_STACK_PALETTE = STACK_PALETTE
ENERGY_KIND_STACK_PALETTE = E2E_KIND_STACK_PALETTE
ENERGY_KIND_STACK_GROUPS = E2E_KIND_STACK_GROUPS


def _llama_compact_kwargs(y_label: str) -> dict[str, Any]:
    return {
        "figsize": LLAMA_E2E_STACKED_FIGSIZE,
        "row_height": LLAMA_E2E_STACKED_FIGSIZE[1] / 4,
        "title": None,
        "subplot_title_template": LLAMA_E2E_SUBPLOT_TITLE_TEMPLATE,
        "subplot_title_fontsize": MIN_FONT_SIZE - 0.6,
        "subplot_title_inside": True,
        "subplot_title_replacements": (
            ("Llama 3.2 1B, ", "llama3.2-1B "),
            ("Llama 3.2 3B, ", "llama3.2-3B "),
            ("Llama 2, ", "llama2 "),
            ("Llama 3, ", "llama3 "),
        ),
        "x_label": "",
        "y_label": y_label,
        "x_group_labels_inside": True,
        "legend_position": "top",
        "legend_title": None,
        "legend_y": 0.950,
        "tight_layout_rect": (0.0, 0.02, 1.0, 0.93),
        "tight_layout_h_pad": 0.2,
        "value_labels": VALUE_LABELS,
        "stage_x_tick_label_rotations": {"Prefill": 0.0, "Decode": 45.0},
    }


def _llama_e2e_wide_knobs() -> WideBarKnobs:
    return WideBarKnobs(
        **_llama_compact_kwargs(Y_LABEL),
        legend_ncol=4,
    )


@dataclass
class StackedBarKnobs(WideBarKnobs):
    figsize: tuple[float, float] = GEMM_FIGSIZE
    row_height: float | None = 2.1
    bar_width: float = 0.76
    relative: bool = True
    y_lim_top_scale: float = 1.18
    legend_title: str | None = GEMM_LEGEND_TITLE
    legend_ncol: int | None = 6
    legend_position: str = "bottom"
    legend_y: float = -0.32
    tight_layout_rect: tuple[float, float, float, float] = (0.0, 0.08, 1.0, 0.96)
    stack_palette: tuple[str, ...] | None = None
    stack_groups: tuple[StackGroupKnobs, ...] = ()


def _llama_e2e_stacked_knobs() -> StackedBarKnobs:
    return StackedBarKnobs(
        **_llama_compact_kwargs(Y_LABEL),
        legend_ncol=2,
        stack_palette=E2E_KIND_STACK_PALETTE,
        stack_groups=E2E_KIND_STACK_GROUPS,
    )


@dataclass
class PlotKnobs:
    kernel_dynamic_power: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=KERNEL_DYNAMIC_POWER_FIGSIZE,
            row_height=KERNEL_DYNAMIC_POWER_FIGSIZE[1],
            title=None,
            x_label="kernel kind",
            y_label="dynamic power (W)",
            value_labels=False,
            x_tick_label_rotation=60.0,
            legend_position="none",
            tight_layout_rect=(0.0, 0.0, 1.0, 1.0),
        )
    )
    main_all: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=TWO_COLUMN_FIGSIZE,
            row_height=TWO_COLUMN_FIGSIZE[1],
            title=MAIN_ALL_TITLE,
            y_label=Y_LABEL,
            value_labels=VALUE_LABELS
        )
    )
    gemm_only: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            title=GEMM_ONLY_TITLE,
            y_label=Y_LABEL,
            value_labels=VALUE_LABELS,
            legend_ncol=3,
            stack_palette=GEMM_ONLY_GROUP_PALETTE,
            stack_groups=GEMM_ONLY_STACK_GROUPS,
        )
    )
    energy: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            figsize=TWO_COLUMN_FIGSIZE,
            row_height=TWO_COLUMN_FIGSIZE[1],
            title=ENERGY_TITLE,
            y_label=ENERGY_Y_LABEL,
            value_labels=VALUE_LABELS
        )
    )
    llama_e2e: WideBarKnobs = field(
        default_factory=_llama_e2e_wide_knobs
    )
    llama_e2e_no_area_norm: WideBarKnobs = field(
        default_factory=_llama_e2e_wide_knobs
    )
    llama_e2e_no_area_norm_stacked: StackedBarKnobs = field(
        default_factory=_llama_e2e_stacked_knobs
    )
    llama_e2e_gemm_layout_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(Y_LABEL),
            legend_ncol=2,
            stack_palette=E2E_GEMM_LAYOUT_STACK_PALETTE,
        )
    )
    llama_e2e_gemm_layout_vector_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(Y_LABEL),
            legend_ncol=3,
            stack_palette=E2E_GEMM_LAYOUT_VECTOR_STACK_PALETTE,
        )
    )
    llama_e2e_stacked: StackedBarKnobs = field(
        default_factory=_llama_e2e_stacked_knobs
    )
    llama_gemm_only: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(Y_LABEL),
            legend_ncol=3,
            stack_palette=GEMM_ONLY_GROUP_PALETTE,
            stack_groups=GEMM_ONLY_STACK_GROUPS,
        )
    )
    llama_gemm_only_no_area_norm: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(Y_LABEL),
            legend_ncol=3,
            stack_palette=GEMM_ONLY_GROUP_PALETTE,
            stack_groups=GEMM_ONLY_STACK_GROUPS,
        )
    )
    llama_gemm_only_energy: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=3,
            stack_palette=GEMM_ONLY_GROUP_PALETTE,
            stack_groups=GEMM_ONLY_STACK_GROUPS,
        )
    )
    llama_gemm_only_energy_no_area_norm: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=3,
            stack_palette=GEMM_ONLY_GROUP_PALETTE,
            stack_groups=GEMM_ONLY_STACK_GROUPS,
        )
    )
    llama_energy: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=4,
        )
    )
    llama_energy_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=2,
            stack_palette=ENERGY_KIND_STACK_PALETTE,
            stack_groups=ENERGY_KIND_STACK_GROUPS,
        )
    )
    llama_energy_no_area_norm: WideBarKnobs = field(
        default_factory=lambda: WideBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=4,
        )
    )
    llama_energy_no_area_norm_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=2,
            stack_palette=ENERGY_KIND_STACK_PALETTE,
            stack_groups=ENERGY_KIND_STACK_GROUPS,
        )
    )
    llama_energy_gemm_layout_vector_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=4,
            stack_palette=E2E_GEMM_LAYOUT_VECTOR_DEQUANT_STACK_PALETTE,
        )
    )
    llama_energy_no_area_norm_gemm_layout_vector_stacked: StackedBarKnobs = field(
        default_factory=lambda: StackedBarKnobs(
            **_llama_compact_kwargs(ENERGY_Y_LABEL),
            legend_ncol=4,
            stack_palette=E2E_GEMM_LAYOUT_VECTOR_DEQUANT_STACK_PALETTE,
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
        help=(
            "plot to generate: main_all, gemm_only, energy, llama_e2e, "
            "llama_e2e_no_area_norm, llama_e2e_no_area_norm_stacked, "
            "llama_e2e_gemm_layout_stacked, llama_e2e_gemm_layout_vector_stacked, "
            "llama_e2e_stacked, llama_gemm_only, "
            "llama_gemm_only_no_area_norm, llama_gemm_only_energy, "
            "llama_gemm_only_energy_no_area_norm, llama_energy, "
            "llama_energy_no_area_norm, llama_energy_stacked, "
            "llama_energy_no_area_norm_stacked, "
            "llama_energy_gemm_layout_vector_stacked, "
            "llama_energy_no_area_norm_gemm_layout_vector_stacked, "
            "kernel_dynamic_power, "
            "latency, or all"
        ),
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
        "--llama3p2-1b-data",
        default=None,
        help="Llama 3.2 1B E2E prepared directory or excel_figure_data.csv for --plot llama_e2e.",
    )
    parser.add_argument(
        "--llama3p2-3b-data",
        default=None,
        help="Llama 3.2 3B E2E prepared directory or excel_figure_data.csv for --plot llama_e2e.",
    )
    parser.add_argument(
        "--llama2-no-area-norm-data",
        default=None,
        help="Llama 2 E2E data without area normalization for --plot llama_e2e_no_area_norm.",
    )
    parser.add_argument(
        "--llama3-no-area-norm-data",
        default=None,
        help="Llama 3 E2E data without area normalization for --plot llama_e2e_no_area_norm.",
    )
    parser.add_argument(
        "--llama3p2-1b-no-area-norm-data",
        default=None,
        help="Llama 3.2 1B E2E data without area normalization for --plot llama_e2e_no_area_norm.",
    )
    parser.add_argument(
        "--llama3p2-3b-no-area-norm-data",
        default=None,
        help="Llama 3.2 3B E2E data without area normalization for --plot llama_e2e_no_area_norm.",
    )
    parser.add_argument(
        "--llama2-no-area-norm-stacked-data",
        default=None,
        help="Llama 2 stacked E2E data without area normalization for --plot llama_e2e_no_area_norm_stacked.",
    )
    parser.add_argument(
        "--llama3-no-area-norm-stacked-data",
        default=None,
        help="Llama 3 stacked E2E data without area normalization for --plot llama_e2e_no_area_norm_stacked.",
    )
    parser.add_argument(
        "--llama3p2-1b-no-area-norm-stacked-data",
        default=None,
        help="Llama 3.2 1B stacked E2E data without area normalization for --plot llama_e2e_no_area_norm_stacked.",
    )
    parser.add_argument(
        "--llama3p2-3b-no-area-norm-stacked-data",
        default=None,
        help="Llama 3.2 3B stacked E2E data without area normalization for --plot llama_e2e_no_area_norm_stacked.",
    )
    parser.add_argument(
        "--llama2-e2e-stacked-data",
        default=None,
        help="Llama 2 stacked E2E prepared directory or excel_figure_data.csv for --plot llama_e2e_stacked.",
    )
    parser.add_argument(
        "--llama3-e2e-stacked-data",
        default=None,
        help="Llama 3 stacked E2E prepared directory or excel_figure_data.csv for --plot llama_e2e_stacked.",
    )
    parser.add_argument(
        "--llama3p2-1b-e2e-stacked-data",
        default=None,
        help="Llama 3.2 1B stacked E2E prepared directory or excel_figure_data.csv for --plot llama_e2e_stacked.",
    )
    parser.add_argument(
        "--llama3p2-3b-e2e-stacked-data",
        default=None,
        help="Llama 3.2 3B stacked E2E prepared directory or excel_figure_data.csv for --plot llama_e2e_stacked.",
    )
    parser.add_argument(
        "--llama2-e2e-gemm-layout-stacked-data",
        default=None,
        help="Llama 2 name/backend-stacked E2E data for the GEMM/layout stacked plots.",
    )
    parser.add_argument(
        "--llama3-e2e-gemm-layout-stacked-data",
        default=None,
        help="Llama 3 name/backend-stacked E2E data for the GEMM/layout stacked plots.",
    )
    parser.add_argument(
        "--llama3p2-1b-e2e-gemm-layout-stacked-data",
        default=None,
        help="Llama 3.2 1B name/backend-stacked E2E data for the GEMM/layout stacked plots.",
    )
    parser.add_argument(
        "--llama3p2-3b-e2e-gemm-layout-stacked-data",
        default=None,
        help="Llama 3.2 3B name/backend-stacked E2E data for the GEMM/layout stacked plots.",
    )
    parser.add_argument(
        "--llama2-gemm-data",
        default=None,
        help="Llama 2 GEMM-only prepared directory or excel_figure_data.csv for --plot llama_gemm_only.",
    )
    parser.add_argument(
        "--llama3-gemm-data",
        default=None,
        help="Llama 3 GEMM-only prepared directory or excel_figure_data.csv for --plot llama_gemm_only.",
    )
    parser.add_argument(
        "--llama3p2-1b-gemm-data",
        default=None,
        help="Llama 3.2 1B GEMM-only prepared directory or excel_figure_data.csv for --plot llama_gemm_only.",
    )
    parser.add_argument(
        "--llama3p2-3b-gemm-data",
        default=None,
        help="Llama 3.2 3B GEMM-only prepared directory or excel_figure_data.csv for --plot llama_gemm_only.",
    )
    parser.add_argument(
        "--llama2-gemm-no-area-norm-data",
        default=None,
        help="Llama 2 GEMM-only data without area normalization for --plot llama_gemm_only_no_area_norm.",
    )
    parser.add_argument(
        "--llama3-gemm-no-area-norm-data",
        default=None,
        help="Llama 3 GEMM-only data without area normalization for --plot llama_gemm_only_no_area_norm.",
    )
    parser.add_argument(
        "--llama3p2-1b-gemm-no-area-norm-data",
        default=None,
        help="Llama 3.2 1B GEMM-only data without area normalization for --plot llama_gemm_only_no_area_norm.",
    )
    parser.add_argument(
        "--llama3p2-3b-gemm-no-area-norm-data",
        default=None,
        help="Llama 3.2 3B GEMM-only data without area normalization for --plot llama_gemm_only_no_area_norm.",
    )
    parser.add_argument(
        "--llama2-gemm-energy-data",
        default=None,
        help="Llama 2 GEMM-only energy data for --plot llama_gemm_only_energy.",
    )
    parser.add_argument(
        "--llama3-gemm-energy-data",
        default=None,
        help="Llama 3 GEMM-only energy data for --plot llama_gemm_only_energy.",
    )
    parser.add_argument(
        "--llama3p2-1b-gemm-energy-data",
        default=None,
        help="Llama 3.2 1B GEMM-only energy data for --plot llama_gemm_only_energy.",
    )
    parser.add_argument(
        "--llama3p2-3b-gemm-energy-data",
        default=None,
        help="Llama 3.2 3B GEMM-only energy data for --plot llama_gemm_only_energy.",
    )
    parser.add_argument(
        "--llama2-energy-data",
        default=None,
        help="Llama 2 energy prepared directory or excel_figure_data.csv for --plot llama_energy.",
    )
    parser.add_argument(
        "--llama3-energy-data",
        default=None,
        help="Llama 3 energy prepared directory or excel_figure_data.csv for --plot llama_energy.",
    )
    parser.add_argument(
        "--llama3p2-1b-energy-data",
        default=None,
        help="Llama 3.2 1B energy prepared directory or excel_figure_data.csv for --plot llama_energy.",
    )
    parser.add_argument(
        "--llama3p2-3b-energy-data",
        default=None,
        help="Llama 3.2 3B energy prepared directory or excel_figure_data.csv for --plot llama_energy.",
    )
    parser.add_argument(
        "--llama2-energy-stacked-data",
        default=None,
        help="Llama 2 stacked energy prepared directory or excel_figure_data.csv for --plot llama_energy_stacked.",
    )
    parser.add_argument(
        "--llama3-energy-stacked-data",
        default=None,
        help="Llama 3 stacked energy prepared directory or excel_figure_data.csv for --plot llama_energy_stacked.",
    )
    parser.add_argument(
        "--llama3p2-1b-energy-stacked-data",
        default=None,
        help="Llama 3.2 1B stacked energy prepared directory or excel_figure_data.csv for --plot llama_energy_stacked.",
    )
    parser.add_argument(
        "--llama3p2-3b-energy-stacked-data",
        default=None,
        help="Llama 3.2 3B stacked energy prepared directory or excel_figure_data.csv for --plot llama_energy_stacked.",
    )
    parser.add_argument(
        "--llama2-energy-gemm-layout-vector-stacked-data",
        default=None,
        help="Llama 2 name/backend-stacked energy data for --plot llama_energy_gemm_layout_vector_stacked.",
    )
    parser.add_argument(
        "--llama3-energy-gemm-layout-vector-stacked-data",
        default=None,
        help="Llama 3 name/backend-stacked energy data for --plot llama_energy_gemm_layout_vector_stacked.",
    )
    parser.add_argument(
        "--llama3p2-1b-energy-gemm-layout-vector-stacked-data",
        default=None,
        help="Llama 3.2 1B name/backend-stacked energy data for --plot llama_energy_gemm_layout_vector_stacked.",
    )
    parser.add_argument(
        "--llama3p2-3b-energy-gemm-layout-vector-stacked-data",
        default=None,
        help="Llama 3.2 3B name/backend-stacked energy data for --plot llama_energy_gemm_layout_vector_stacked.",
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
        return all(
            token not in name
            for token in (
                "e2e_no_area_norm",
                "e2e_gemm_layout_stacked",
                "e2e_stacked",
                "gemm_only",
                "energy_per_token",
                "llama_compare",
            )
        )
    if kind == "e2e_no_area_norm":
        return "e2e_no_area_norm" in name and "stacked_by_kind" not in name
    if kind == "e2e_no_area_norm_stacked":
        return "e2e_no_area_norm_stacked_by_kind" in name
    if kind == "e2e_gemm_layout_stacked":
        return "e2e_gemm_layout_stacked_by_name_backend" in name
    if kind == "e2e_stacked":
        return "e2e_stacked_by_kind" in name
    if kind == "gemm_only_no_area_norm":
        return "gemm_only_no_area_norm" in name
    if kind == "gemm_only_energy":
        return (
            "gemm_only_energy_per_token_stacked_by_name" in name
            and "no_area_norm" not in name
        )
    if kind == "gemm_only_energy_no_area_norm":
        return "gemm_only_energy_per_token_no_area_norm_stacked_by_name" in name
    if kind == "gemm_only":
        return (
            "gemm_only" in name
            and "gemm_only_no_area_norm" not in name
            and "gemm_only_energy_per_token" not in name
        )
    if kind == "energy":
        return (
            "energy_per_token" in name
            and "no_area_norm" not in name
            and "stacked_by_kind" not in name
            and "gemm_layout_vector_stacked_by_name_backend" not in name
            and "gemm_only_energy_per_token" not in name
        )
    if kind == "energy_stacked":
        return (
            "energy_per_token_stacked_by_kind" in name
            and "no_area_norm" not in name
        )
    if kind == "energy_gemm_layout_vector_stacked":
        return (
            "energy_per_token_gemm_layout_vector_stacked_by_name_backend" in name
            and "no_area_norm" not in name
        )
    if kind == "energy_no_area_norm":
        return (
            "energy_per_token_no_area_norm" in name
            and "stacked_by_kind" not in name
            and "gemm_layout_vector_stacked_by_name_backend" not in name
            and "gemm_only_energy_per_token" not in name
        )
    if kind == "energy_no_area_norm_stacked":
        return "energy_per_token_no_area_norm_stacked_by_kind" in name
    if kind == "energy_no_area_norm_gemm_layout_vector_stacked":
        return (
            "energy_per_token_no_area_norm_"
            "gemm_layout_vector_stacked_by_name_backend"
        ) in name
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


def _discover_model_csv(prepared_root: Path, model_key: str, kind: str, label: str) -> Path:
    if not prepared_root.exists():
        raise FileNotFoundError(f"prepared root does not exist: {prepared_root}")
    candidates = []
    for path in prepared_root.glob(f"*/{EXCEL_FIGURE_DATA_CSV}"):
        name = path.parent.name
        if model_key not in name:
            continue
        if not _candidate_matches_kind(path, kind):
            continue
        candidates.append(path)
    if not candidates:
        raise FileNotFoundError(f"no {model_key} {label} {EXCEL_FIGURE_DATA_CSV} found under {prepared_root}")
    candidates.sort(key=lambda path: (path.stat().st_mtime, str(path)), reverse=True)
    selected = candidates[0]
    print(f"{model_key} {label} data: {selected}")
    return selected


def _energy_csv_power_metric(path: Path) -> str | None:
    name = path.parent.name
    for metric in ENERGY_POWER_METRICS:
        if metric in name:
            return metric
    try:
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            if "power_metric" not in (reader.fieldnames or ()):
                return None
            for row in reader:
                value = str(row.get("power_metric", "")).strip()
                return value or None
    except OSError:
        return None
    return None


def _validate_energy_csv_schema(path: Path, kind: str) -> str:
    with path.open(newline="") as handle:
        columns = set(csv.DictReader(handle).fieldnames or ())
    required = {"power_metric", "stage", "batch", "seq"}
    if kind in {
        "energy_stacked",
        "energy_gemm_layout_vector_stacked",
        "gemm_only_energy",
        "energy_no_area_norm_stacked",
        "energy_no_area_norm_gemm_layout_vector_stacked",
        "gemm_only_energy_no_area_norm",
    }:
        required.update(("candidate", "total"))
    elif kind in {"energy", "energy_no_area_norm"}:
        if not columns.intersection(E2E_CANDIDATE_COLUMNS):
            raise ValueError(f"flat energy data has no candidate columns: {path}")
    else:
        raise ValueError(f"unsupported energy data kind: {kind}")
    missing = required - columns
    if missing:
        raise ValueError(f"{kind} data missing columns {sorted(missing)}: {path}")

    power_metric = _energy_csv_power_metric(path)
    if not power_metric:
        raise ValueError(f"{kind} data has no power_metric value: {path}")
    return power_metric


def _discover_model_energy_csv(
    prepared_root: Path,
    model_key: str,
    power_metric: str,
    *,
    kind: str = "energy",
) -> Path:
    if not prepared_root.exists():
        raise FileNotFoundError(f"prepared root does not exist: {prepared_root}")
    candidates = []
    for path in prepared_root.glob(f"*/{EXCEL_FIGURE_DATA_CSV}"):
        if model_key not in path.parent.name:
            continue
        if not _candidate_matches_kind(path, kind):
            continue
        if _energy_csv_power_metric(path) != power_metric:
            continue
        candidates.append(path)
    if not candidates:
        raise FileNotFoundError(
            f"no {model_key} {kind} {power_metric} {EXCEL_FIGURE_DATA_CSV} found under {prepared_root}"
        )
    candidates.sort(key=lambda path: (path.stat().st_mtime, str(path)), reverse=True)
    selected = candidates[0]
    print(f"{model_key} {kind} {power_metric} data: {selected}")
    return selected


def _discover_model_e2e_csv(prepared_root: Path, model_key: str) -> Path:
    return _discover_model_csv(prepared_root, model_key, "main_all", "E2E")


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
    return model_csv_path(
        explicit=explicit,
        prepared_root=prepared_root,
        latency_dir=latency_dir,
        model_key=model_key,
        kind="main_all",
        label="E2E",
    )


def model_csv_path(
    *,
    explicit: str | None,
    prepared_root: Path,
    latency_dir: Path,
    model_key: str,
    kind: str,
    label: str,
) -> Path:
    if explicit:
        csv_path = _prepared_csv_from_path(resolve_under_latency_dir(explicit, latency_dir, prefer_existing=True))
    else:
        csv_path = _discover_model_csv(prepared_root, model_key, kind, label)
    if not csv_path.exists():
        raise FileNotFoundError(csv_path)
    if csv_path.name != EXCEL_FIGURE_DATA_CSV:
        raise ValueError(f"plot.py only reads {EXCEL_FIGURE_DATA_CSV}: {csv_path}")
    return csv_path


def model_energy_csv_path(
    *,
    explicit: str | None,
    prepared_root: Path,
    latency_dir: Path,
    model_key: str,
    power_metric: str,
    kind: str = "energy",
) -> Path:
    if explicit:
        csv_path = _prepared_csv_from_path(resolve_under_latency_dir(explicit, latency_dir, prefer_existing=True))
    else:
        csv_path = _discover_model_energy_csv(
            prepared_root,
            model_key,
            power_metric,
            kind=kind,
        )
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


def _stage_bar_width(
    knobs: WideBarKnobs,
    stage: Any,
    base_width: float,
    *,
    max_width: float,
) -> float:
    scale = float(knobs.stage_bar_width_scales.get(str(stage), 1.0))
    if not math.isfinite(scale) or scale <= 0.0:
        raise ValueError("stage bar width scale must be a positive finite number")
    width = min(float(base_width) * scale, float(max_width))
    if not math.isfinite(width) or width <= 0.0:
        raise ValueError("bar width must be a positive finite number")
    return width


def _plot_knobs_from_args(args: argparse.Namespace) -> PlotKnobs:
    knobs: PlotKnobs = copy.deepcopy(PLOT_KNOBS)
    plot_knobs: list[WideBarKnobs] = [
        knobs.kernel_dynamic_power,
        knobs.main_all,
        knobs.gemm_only,
        knobs.energy,
        knobs.llama_e2e,
        knobs.llama_e2e_no_area_norm,
        knobs.llama_e2e_no_area_norm_stacked,
        knobs.llama_e2e_gemm_layout_stacked,
        knobs.llama_e2e_gemm_layout_vector_stacked,
        knobs.llama_e2e_stacked,
        knobs.llama_gemm_only,
        knobs.llama_gemm_only_no_area_norm,
        knobs.llama_gemm_only_energy,
        knobs.llama_gemm_only_energy_no_area_norm,
        knobs.llama_energy,
        knobs.llama_energy_no_area_norm,
        knobs.llama_energy_stacked,
        knobs.llama_energy_no_area_norm_stacked,
        knobs.llama_energy_gemm_layout_vector_stacked,
        knobs.llama_energy_no_area_norm_gemm_layout_vector_stacked,
    ]

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


def _format_subplot_title(knobs: WideBarKnobs, **values: Any) -> str:
    title = _format_template(knobs.subplot_title_template, **values)
    for source, replacement in knobs.subplot_title_replacements:
        title = title.replace(source, replacement)
    return title


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
        stack_columns = _ordered_unique(export["legend"].dropna().astype(str).tolist())
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

    options = argparse.Namespace(label_maps=label_maps)
    export["stage"] = export["stage"].map(lambda value: _display_label("stage", value, options)) if "stage" in export else ""
    export["batch"] = export["batch"] if "batch" in export else ""
    export["seq"] = export["seq_len"].map(_format_seq_for_excel) if "seq_len" in export else ""
    export["seq_sort"] = export["seq_len"].map(_seq_sort_key) if "seq_len" in export else 0
    export["legend"] = export["variant"].map(lambda value: _display_label("variant", value, options)) if "variant" in export else ""
    export["power_metric"] = export["power_metric"] if "power_metric" in export else ""
    export["relative_value"] = export[value_col].astype(float) if value_col in export else []
    export = export.sort_values(["stage", "batch", "seq_sort", "legend"])
    index_columns = ["stage", "batch", "seq_sort", "seq"]
    if "power_metric" in export.columns:
        index_columns.insert(0, "power_metric")
    wide = (
        export.pivot_table(
            index=index_columns,
            columns="legend",
            values="relative_value",
            aggfunc="sum",
        )
        .reset_index()
        .rename_axis(None, axis=1)
        .sort_values(["stage", "batch", "seq_sort"])
    )
    _ensure_columns(wide, E2E_CANDIDATE_COLUMNS)
    columns = [column for column in ("power_metric", "stage", "batch", "seq") if column in wide.columns]
    wide = wide[[*columns, *E2E_CANDIDATE_COLUMNS]]

    path = result.figure_path.parent / EXCEL_FIGURE_DATA_CSV
    path.parent.mkdir(parents=True, exist_ok=True)
    wide.to_csv(path, index=False)
    print(f"wrote {path}")
    return path


def write_energy_stacked_figure_data_csv(
    result: EnergyExcelResult,
    *,
    label_maps: dict[str, dict[Any, str]],
    stack_by: str = "kind",
) -> Path:
    """Write candidate rows with relative energy split across kernel kinds."""
    summary = result.summary.copy()
    value_col = "relative_joules_per_token"
    required = {"stage", "batch", "seq_len", "variant", stack_by, value_col}
    missing = required - set(summary.columns)
    if missing:
        raise ValueError(f"stacked energy summary missing columns: {sorted(missing)}")

    options = argparse.Namespace(label_maps=label_maps)
    export = summary[summary[value_col].notna()].copy()
    export["stage"] = export["stage"].map(lambda value: _display_label("stage", value, options))
    export["seq"] = export["seq_len"].map(_format_seq_for_excel)
    export["seq_sort"] = export["seq_len"].map(_seq_sort_key)
    export["candidate"] = export["variant"].map(
        lambda value: _display_label("variant", value, options)
    )
    export["legend"] = export[stack_by].astype(str)
    export["relative_value"] = export[value_col].astype(float)
    export = export.sort_values(
        ["power_metric", "stage", "batch", "seq_sort", "candidate", "legend"]
    )
    stack_columns = _ordered_unique(export["legend"].dropna().astype(str).tolist())
    wide = (
        export.pivot_table(
            index=["power_metric", "stage", "batch", "seq_sort", "seq", "candidate"],
            columns="legend",
            values="relative_value",
            aggfunc="sum",
        )
        .reset_index()
        .rename_axis(None, axis=1)
        .sort_values(["power_metric", "stage", "batch", "seq_sort", "candidate"])
    )
    value_columns = _wide_value_columns(
        wide.drop(
            columns=["power_metric", "stage", "batch", "seq_sort", "seq", "candidate"]
        ),
        stack_columns,
    )
    wide["total"] = wide[value_columns].sum(axis=1, skipna=True)
    wide = wide[
        [
            "power_metric",
            "stage",
            "batch",
            "seq_sort",
            "seq",
            "candidate",
            *value_columns,
            "total",
        ]
    ]
    wide["batch"] = wide["batch"].astype(str)
    wide["seq"] = wide["seq"].astype(str)
    repeated_group = wide[["power_metric", "stage", "batch", "seq_sort"]].duplicated()
    wide.loc[repeated_group, ["batch", "seq"]] = ""
    wide = wide.drop(columns=["seq_sort"])

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
        df["stage"] = df["stage"].map(
            lambda value: "Decode" if str(value).lower() == "generation" else value
        )
    return df


def _save_figure(fig: Any, path: Path, knobs: WideBarKnobs) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _fit_auto_value_labels(fig, knobs)
    if knobs.save_png:
        fig.savefig(path, dpi=knobs.dpi, bbox_inches="tight")
        print(f"wrote {path}")
    if knobs.save_pdf:
        fig.savefig(path.with_suffix(".pdf"), bbox_inches="tight")
        print(f"wrote {path.with_suffix('.pdf')}")
    if knobs.save_svg:
        fig.savefig(path.with_suffix(".svg"), bbox_inches="tight")
        print(f"wrote {path.with_suffix('.svg')}")


def _set_grouped_x_ticks(
    ax: Any,
    stage_df: Any,
    positions: Sequence[float],
    *,
    include_batch: bool,
    knobs: WideBarKnobs,
) -> None:
    stage = str(stage_df["stage"].iloc[0]) if "stage" in stage_df.columns and not stage_df.empty else ""
    tick_label_rotation = knobs.stage_x_tick_label_rotations.get(
        stage,
        knobs.x_tick_label_rotation,
    )
    grouped_positions: dict[tuple[str, str], list[float]] = {}
    for position, (_, row) in zip(positions, stage_df.iterrows()):
        group = (str(row["batch"]), str(row["seq"]))
        grouped_positions.setdefault(group, []).append(position)

    tick_positions: list[float] = []
    tick_labels: list[str] = []
    batch_positions: dict[str, list[float]] = {}
    for (batch, seq), group_positions in grouped_positions.items():
        center = (group_positions[0] + group_positions[-1]) / 2.0
        tick_positions.append(center)
        tick_labels.append(seq if include_batch else f"seq {seq}")
        batch_positions.setdefault(batch, []).append(center)

    ax.set_xticks(tick_positions)
    ax.set_xticklabels(
        tick_labels,
        fontsize=knobs.tick_label_fontsize,
        rotation=tick_label_rotation,
    )
    if not include_batch:
        return

    batch_tick_positions = [
        (centers[0] + centers[-1]) / 2.0
        for centers in batch_positions.values()
    ]
    batch_tick_labels = [
        f"b{_format_batch(batch)}"
        for batch in batch_positions
    ]
    if knobs.x_group_labels_inside:
        for position, label in zip(batch_tick_positions, batch_tick_labels):
            ax.text(
                position,
                knobs.x_group_label_y,
                label,
                transform=ax.get_xaxis_transform(),
                ha="center",
                va="top",
                fontsize=knobs.tick_label_fontsize,
                color="0.25",
            )
        return

    ax.set_xticks(batch_tick_positions, minor=True)
    ax.set_xticklabels(
        batch_tick_labels,
        minor=True,
        fontsize=knobs.tick_label_fontsize,
        rotation=0.0,
    )
    group_label_pad = 14 if tick_label_rotation == 0 else 22
    ax.tick_params(axis="x", which="minor", length=0, pad=group_label_pad)


def _initial_value_label_fontsize(knobs: WideBarKnobs) -> float:
    if knobs.value_label_fontsize == "auto":
        fontsize = float(knobs.value_label_auto_max_fontsize)
    else:
        fontsize = float(knobs.value_label_fontsize)
    if not math.isfinite(fontsize) or fontsize <= 0.0:
        raise ValueError("value label font size must be a positive finite number or 'auto'")
    return fontsize


def _mark_auto_value_label(artist: Any, bar_width: float) -> None:
    artist._value_label_bar_width = abs(float(bar_width))


def _mark_stacked_value_label(
    artist: Any,
    total: float,
) -> None:
    artist._stacked_value_label_total = float(total)


def _fit_auto_value_labels(fig: Any, knobs: WideBarKnobs) -> None:
    original_dpi = float(fig.dpi)
    fit_dpi = max(original_dpi, min(float(knobs.dpi), 300.0))
    fig.set_dpi(fit_dpi)
    try:
        if knobs.value_label_fontsize == "auto":
            for _pass in range(2):
                fig.canvas.draw()
                renderer = fig.canvas.get_renderer()
                for ax in fig.axes:
                    for artist in ax.texts:
                        bar_width = getattr(artist, "_value_label_bar_width", None)
                        if bar_width is None or bar_width <= 0.0:
                            continue
                        center_x = float(artist.get_position()[0])
                        left_px = ax.transData.transform(
                            (center_x - bar_width / 2.0, 0.0)
                        )[0]
                        right_px = ax.transData.transform(
                            (center_x + bar_width / 2.0, 0.0)
                        )[0]
                        available_width = (
                            abs(float(right_px - left_px))
                            * VALUE_LABEL_AUTO_WIDTH_SCALE
                        )
                        label_width = float(
                            artist.get_window_extent(renderer=renderer).width
                        )
                        if available_width <= 0.0 or label_width <= available_width:
                            continue
                        fitted_fontsize = (
                            artist.get_fontsize()
                            * available_width
                            / label_width
                            * 0.98
                        )
                        artist.set_fontsize(max(fitted_fontsize, 0.1))

        # This pass is also needed when a fixed label font size is selected.
        # Keep labels above the bar by default. Move only labels that collide
        # with the axes boundary or another text into their top segment.
        fig.canvas.draw()
        renderer = fig.canvas.get_renderer()
        for ax in fig.axes:
            stacked_artists = [
                artist
                for artist in ax.texts
                if hasattr(artist, "_stacked_value_label_total")
                and artist.get_visible()
            ]
            label_boxes = {
                artist: artist.get_window_extent(renderer=renderer)
                for artist in stacked_artists
            }
            other_texts = [artist for artist in ax.texts if artist not in stacked_artists]
            other_boxes = [
                artist.get_window_extent(renderer=renderer)
                for artist in other_texts
                if artist.get_visible()
            ]
            if ax.title.get_visible() and ax.title.get_text():
                other_boxes.append(ax.title.get_window_extent(renderer=renderer))

            for artist in stacked_artists:
                label_box = label_boxes[artist]
                collides = label_box.y1 > ax.bbox.y1 - STACKED_LABEL_EDGE_PADDING_PX
                if not collides:
                    collides = any(
                        label_box.overlaps(other_box)
                        for other_box in other_boxes
                    )
                if not collides:
                    collides = any(
                        label_box.overlaps(other_box)
                        for other_artist, other_box in label_boxes.items()
                        if other_artist is not artist and other_artist.get_visible()
                    )
                if not collides:
                    continue

                total = float(artist._stacked_value_label_total)
                artist.set_position((artist.get_position()[0], total))
                artist.set_va("top")
                artist.set_color("white")

        if knobs.value_label_fontsize != "auto":
            return

        # Hide labels that still do not fit their bar after auto-sizing.
        fig.canvas.draw()
        renderer = fig.canvas.get_renderer()
        for ax in fig.axes:
            for artist in ax.texts:
                bar_width = getattr(artist, "_value_label_bar_width", None)
                if bar_width is None or bar_width <= 0.0:
                    continue
                if not artist.get_visible():
                    continue
                center_x = float(artist.get_position()[0])
                left_px = ax.transData.transform(
                    (center_x - bar_width / 2.0, 0.0)
                )[0]
                right_px = ax.transData.transform(
                    (center_x + bar_width / 2.0, 0.0)
                )[0]
                available_width = (
                    abs(float(right_px - left_px))
                    * VALUE_LABEL_AUTO_WIDTH_SCALE
                )
                label_width = float(
                    artist.get_window_extent(renderer=renderer).width
                )
                if label_width > available_width:
                    artist.set_visible(False)
    finally:
        fig.set_dpi(original_dpi)


def _add_value_labels(ax: Any, bars: Any, knobs: WideBarKnobs) -> None:
    fontsize = _initial_value_label_fontsize(knobs)
    for bar in bars:
        height = bar.get_height()
        if not math.isfinite(float(height)) or abs(float(height)) < 1.0e-12:
            continue
        artist = ax.text(
            bar.get_x() + bar.get_width() / 2,
            height + knobs.value_label_dy,
            knobs.value_label_format.format(height),
            ha=knobs.value_label_ha,
            va=knobs.value_label_va,
            rotation=knobs.value_label_rotation,
            fontsize=fontsize,
        )
        _mark_auto_value_label(artist, bar.get_width())


def _add_stacked_total_labels(
    ax: Any,
    positions: Sequence[float],
    totals: Sequence[float],
    knobs: StackedBarKnobs,
    *,
    bar_width: float,
) -> None:
    fontsize = _initial_value_label_fontsize(knobs)
    for position, total in zip(
        positions,
        totals,
    ):
        if not math.isfinite(float(total)) or abs(float(total)) < 1.0e-12:
            continue
        artist = ax.text(
            position,
            total + knobs.value_label_dy,
            knobs.value_label_format.format(total),
            ha=knobs.value_label_ha,
            va=knobs.value_label_va,
            rotation=knobs.value_label_rotation,
            fontsize=fontsize,
        )
        _mark_auto_value_label(artist, bar_width)
        _mark_stacked_value_label(artist, total)


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


def _apply_subplot_x_margin(ax: Any, knobs: WideBarKnobs) -> None:
    margin = float(knobs.subplot_x_margin)
    if not math.isfinite(margin) or margin < 0.0:
        raise ValueError("subplot_x_margin must be a non-negative finite number")
    ax.margins(x=margin)


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

        include_batch = knobs.x_group_axis == "batch"
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

        value_count = max(len(value_columns), 1)
        base_width = min(knobs.bar_width, 0.78 / value_count)
        width = _stage_bar_width(
            knobs,
            stage,
            base_width,
            max_width=MAX_BAR_FILL_RATIO / value_count,
        )
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
        _set_grouped_x_ticks(
            ax,
            stage_df,
            positions,
            include_batch=include_batch,
            knobs=knobs,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max((float(value) for column in value_columns for value in stage_df[column].fillna(0.0)), default=1.0)
        _apply_subplot_x_margin(ax, knobs)
        _apply_y_limits(ax, stage, ymax, knobs)

    handles, labels = axes_list[0].get_legend_handles_labels()
    _add_top_legend(fig, handles, labels, len(value_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    if knobs.x_label:
        fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(
        rect=knobs.tight_layout_rect,
        pad=knobs.tight_layout_pad,
        h_pad=knobs.tight_layout_h_pad,
    )
    _save_figure(fig, out_dir / filename, knobs)
    plt.close(fig)


def _stack_value_columns(pd: Any, df: Any) -> list[str]:
    excluded = {"stage", "batch", "seq", "candidate", "total"}
    columns = _numeric_columns(pd, df, excluded)
    return [column for column in columns if column != "total"]


LAYOUT_FUSED_BACKEND_MARKER = "_layout_fused"
NAME_BACKEND_SEPARATOR = "::"


def _layout_base_backend(layout_backend: str) -> str:
    prefix, marker, suffix = layout_backend.partition(LAYOUT_FUSED_BACKEND_MARKER)
    if not marker or not prefix:
        raise ValueError(f"not a layout-fused backend: {layout_backend!r}")
    return f"{prefix}{suffix}"


def _split_name_backend(stack_column: str) -> tuple[str | None, str]:
    if NAME_BACKEND_SEPARATOR not in stack_column:
        return None, stack_column
    name, backend = stack_column.split(NAME_BACKEND_SEPARATOR, maxsplit=1)
    if not name or not backend:
        raise ValueError(f"invalid name/backend stack column: {stack_column!r}")
    return name, backend


def _corresponding_base_stack_column(
    layout_column: str,
    c3: Any,
    stack_columns: Sequence[str],
) -> str:
    name, backend = _split_name_backend(layout_column)
    if name is None:
        return _layout_base_backend(backend)

    candidates = [
        column
        for column in stack_columns
        if _split_name_backend(column)[0] == name
        and LAYOUT_FUSED_BACKEND_MARKER not in _split_name_backend(column)[1]
        and abs(float(c3[column])) >= 1.0e-15
    ]
    if len(candidates) != 1:
        raise ValueError(
            f"expected one active C3 stack column corresponding to "
            f"C4 stack column {layout_column!r}; found {candidates}"
        )
    return candidates[0]


def _build_gemm_layout_stack(
    pd: Any,
    df: Any,
    *,
    include_vector: bool = False,
    include_dequant: bool = False,
) -> Any:
    """Reduce backend stacks into GEMM, layout, vector, and optional dequant latency."""
    required = {"model", "stage", "batch", "seq", "candidate"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"backend-stacked E2E data missing columns: {sorted(missing)}")

    backend_columns = _stack_value_columns(pd, df)
    gemm_columns = [
        column
        for column in backend_columns
        if "gemm" in _split_name_backend(column)[1].lower()
    ]
    layout_columns = [
        column
        for column in backend_columns
        if LAYOUT_FUSED_BACKEND_MARKER in _split_name_backend(column)[1]
    ]
    dequant_columns = [
        column
        for column in backend_columns
        if any("dequant" in part.lower() for part in _split_name_backend(column) if part)
    ]
    if not gemm_columns:
        raise ValueError("backend-stacked E2E data has no GEMM backend columns")
    if not layout_columns:
        raise ValueError("backend-stacked E2E data has no layout-fused backend columns")

    values = df.copy()
    for column in backend_columns:
        values[column] = pd.to_numeric(values[column], errors="coerce").fillna(0.0)

    records: list[dict[str, Any]] = []
    group_columns = ["model", "stage", "batch", "seq"]
    for group_key, group in values.groupby(group_columns, sort=False, dropna=False):
        candidates = group["candidate"].astype(str)
        if candidates.duplicated().any():
            duplicates = sorted(candidates[candidates.duplicated(keep=False)].unique())
            raise ValueError(
                f"duplicate candidates {duplicates} for model/stage/batch/seq={group_key}"
            )

        c3_rows = group[candidates.eq("C3")]
        c4_rows = group[candidates.eq("C4")]
        if len(c3_rows) != 1 or len(c4_rows) != 1:
            raise ValueError(
                f"expected one C3 and one C4 row for model/stage/batch/seq={group_key}"
            )
        c3 = c3_rows.iloc[0]
        c4 = c4_rows.iloc[0]

        layout_overhead = 0.0
        for layout_column in layout_columns:
            layout_value = float(c4[layout_column])
            if abs(layout_value) < 1.0e-15:
                continue
            base_column = _corresponding_base_stack_column(
                layout_column,
                c3,
                backend_columns,
            )
            if base_column not in backend_columns:
                raise ValueError(
                    f"missing C3 stack column {base_column!r} corresponding to "
                    f"C4 stack column {layout_column!r} for model/stage/batch/seq={group_key}"
                )
            layout_overhead += layout_value - float(c3[base_column])

        for _, row in group.iterrows():
            candidate = str(row["candidate"])
            gemm_latency = sum(float(row[column]) for column in gemm_columns)
            layout_latency = layout_overhead if candidate == "C4" else 0.0
            record = {
                "model": row["model"],
                "stage": row["stage"],
                "batch": row["batch"],
                "seq": row["seq"],
                "candidate": candidate,
                "gemm": gemm_latency,
                "layout": layout_latency,
            }
            if include_vector:
                actual_dequant_latency = (
                    sum(float(row[column]) for column in dequant_columns)
                    if include_dequant
                    else 0.0
                )
                actual_vector_latency = sum(
                    float(row[column])
                    for column in backend_columns
                    if column not in gemm_columns
                    and (not include_dequant or column not in dequant_columns)
                )
                vector_latency = actual_vector_latency - layout_latency
                record["vector"] = vector_latency
                if include_dequant:
                    record["dequant"] = actual_dequant_latency
                record["total"] = (
                    gemm_latency
                    + layout_latency
                    + vector_latency
                    + actual_dequant_latency
                )
            else:
                record["total"] = gemm_latency + layout_latency
            records.append(record)

    return pd.DataFrame.from_records(records)


def _build_gemm_layout_vector_stack(pd: Any, df: Any) -> Any:
    """Preserve E2E totals while separating C4 fused-layout overhead from vector."""
    return _build_gemm_layout_stack(pd, df, include_vector=True)


def _build_gemm_layout_vector_dequant_stack(pd: Any, df: Any) -> Any:
    """Separate energy into GEMM, layout, vector, and dequant components."""
    return _build_gemm_layout_stack(
        pd,
        df,
        include_vector=True,
        include_dequant=True,
    )


def _apply_stack_groups(
    df: Any,
    stack_columns: Sequence[str],
    groups: Sequence[StackGroupKnobs],
) -> tuple[Any, list[str]]:
    if not groups:
        return df, list(stack_columns)

    remaining_group_count = sum(group.columns is None for group in groups)
    if remaining_group_count > 1:
        raise ValueError("only one stack group may use columns=None")
    labels = [group.label for group in groups]
    if len(labels) != len(set(labels)):
        raise ValueError("stack group labels must be unique")

    explicitly_grouped = {
        column
        for group in groups
        if group.columns is not None
        for column in group.columns
    }
    grouped = df.copy()
    for group in groups:
        source_columns = (
            [column for column in stack_columns if column not in explicitly_grouped]
            if group.columns is None
            else [column for column in group.columns if column in stack_columns]
        )
        grouped[group.label] = grouped[source_columns].sum(axis=1) if source_columns else 0.0
    return grouped, labels


def _apply_relative_stack_values(
    pd: Any,
    df: Any,
    stack_columns: Sequence[str],
) -> Any:
    """Normalize each stack against the smallest positive total at its x tick."""
    if not stack_columns:
        return df

    relative = df.copy()
    group_columns = [
        column
        for column in ("model", "stage", "batch", "seq")
        if column in relative.columns
    ]
    relative["__stack_total"] = relative[list(stack_columns)].sum(axis=1)

    def _positive_min(values: Any) -> float:
        positive = pd.to_numeric(values, errors="coerce").fillna(0.0)
        positive = positive[positive > 0.0]
        return float(positive.min()) if not positive.empty else 1.0

    if group_columns:
        baselines = relative.groupby(
            group_columns,
            sort=False,
            dropna=False,
        )["__stack_total"].transform(_positive_min)
    else:
        baselines = pd.Series(
            _positive_min(relative["__stack_total"]),
            index=relative.index,
        )
    baselines = pd.to_numeric(baselines, errors="coerce").fillna(1.0)
    baselines = baselines.mask(baselines <= 0.0, 1.0)

    for column in stack_columns:
        relative[column] = relative[column] / baselines
    relative["total"] = relative[list(stack_columns)].sum(axis=1)
    return relative.drop(columns=["__stack_total"])


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

    stack_columns = _stack_value_columns(pd, df)
    if not stack_columns:
        raise ValueError(f"{csv_path} has no GEMM stack value columns")
    for column in stack_columns:
        df[column] = pd.to_numeric(df[column], errors="coerce").fillna(0.0)
    df, stack_columns = _apply_stack_groups(df, stack_columns, knobs.stack_groups)
    if knobs.relative:
        df = _apply_relative_stack_values(pd, df, stack_columns)

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

        include_batch = knobs.x_group_axis == "batch"
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

        width = _stage_bar_width(
            knobs,
            stage,
            knobs.bar_width,
            max_width=MAX_BAR_FILL_RATIO,
        )
        bottoms = [0.0 for _ in positions]
        for column in stack_columns:
            values = stage_df[column].tolist()
            ax.bar(
                positions,
                values,
                bottom=bottoms,
                width=width,
                color=colors[column],
                edgecolor=knobs.bar_edgecolor,
                linewidth=knobs.bar_linewidth,
                alpha=knobs.bar_alpha,
                label=column,
            )
            bottoms = [bottom + value for bottom, value in zip(bottoms, values)]
        if knobs.value_labels:
            _add_stacked_total_labels(
                ax,
                positions,
                bottoms,
                knobs,
                bar_width=width,
            )

        ax.set_title(
            _format_template(knobs.subplot_title_template, stage=stage, model=""),
            fontsize=knobs.subplot_title_fontsize,
        )
        ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
        _set_grouped_x_ticks(
            ax,
            stage_df,
            positions,
            include_batch=include_batch,
            knobs=knobs,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max(bottoms, default=1.0)
        _apply_subplot_x_margin(ax, knobs)
        _apply_y_limits(ax, stage, ymax, knobs)

    handles, labels = axes_list[-1].get_legend_handles_labels()
    _add_top_legend(fig, handles, labels, len(stack_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    if knobs.x_label:
        fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(
        rect=knobs.tight_layout_rect,
        pad=knobs.tight_layout_pad,
        h_pad=knobs.tight_layout_h_pad,
    )
    _save_figure(fig, out_dir / "gemm_only_latency.png", knobs)
    plt.close(fig)


def _read_model_excel_frames(
    model_csvs: Sequence[tuple[str, str, Path]],
) -> list[Any]:
    frames = []
    for _model_key, model_label, csv_path in model_csvs:
        df = _read_excel_figure_data(csv_path)
        if df.empty:
            print(f"skip {model_label}: {csv_path} has no rows")
            continue
        df = df.copy()
        df["model"] = model_label
        frames.append(df)
    return frames


def plot_model_wide_candidate_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    filename: str,
    knobs: WideBarKnobs,
) -> None:
    pd, plt = _import_plot_modules()
    frames = _read_model_excel_frames(model_csvs)
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
        subplot_title = _format_subplot_title(
            knobs,
            model=model_label,
            stage=stage,
        )
        if knobs.subplot_title_inside:
            ax.text(
                0.01,
                0.96,
                subplot_title,
                transform=ax.transAxes,
                ha="left",
                va="top",
                fontsize=knobs.subplot_title_fontsize,
                fontweight="bold",
                bbox={"facecolor": "white", "edgecolor": "none", "pad": 0.5},
            )
        else:
            ax.set_title(subplot_title, fontsize=knobs.subplot_title_fontsize)
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

        include_batch = knobs.x_group_axis == "batch"
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

        value_count = max(len(value_columns), 1)
        base_width = min(knobs.bar_width, 0.78 / value_count)
        width = _stage_bar_width(
            knobs,
            stage,
            base_width,
            max_width=MAX_BAR_FILL_RATIO / value_count,
        )
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
        _set_grouped_x_ticks(
            ax,
            stage_df,
            positions,
            include_batch=include_batch,
            knobs=knobs,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max((float(value) for column in value_columns for value in stage_df[column].fillna(0.0)), default=1.0)
        _apply_subplot_x_margin(ax, knobs)
        _apply_y_limits(ax, stage, ymax, knobs)

    _add_top_legend(fig, legend_handles, legend_labels, len(value_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    if knobs.x_label:
        fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(
        rect=knobs.tight_layout_rect,
        pad=knobs.tight_layout_pad,
        h_pad=knobs.tight_layout_h_pad,
    )
    _save_figure(fig, out_dir / filename, knobs)
    plt.close(fig)


def plot_llama_e2e_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_model_wide_candidate_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_latency.png",
        knobs=knobs,
    )


def plot_llama_e2e_no_area_norm_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_model_wide_candidate_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_latency_no_area_norm.png",
        knobs=knobs,
    )


def plot_model_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    filename: str,
    data_label: str,
    knobs: StackedBarKnobs,
    stack_transform: Any | None = None,
) -> None:
    pd, plt = _import_plot_modules()
    frames = _read_model_excel_frames(model_csvs)
    if not frames:
        print(f"skip {knobs.title}: no model rows")
        return

    combined = pd.concat(frames, ignore_index=True)
    required = {"model", "stage", "batch", "seq", "candidate"}
    missing = required - set(combined.columns)
    if missing:
        raise ValueError(f"{data_label} data missing columns: {sorted(missing)}")

    if stack_transform is not None:
        combined = stack_transform(pd, combined)

    stack_columns = _stack_value_columns(pd, combined)
    if not stack_columns:
        raise ValueError(f"{data_label} data has no stack value columns")
    for column in stack_columns:
        combined[column] = pd.to_numeric(combined[column], errors="coerce").fillna(0.0)
    combined, stack_columns = _apply_stack_groups(combined, stack_columns, knobs.stack_groups)
    if knobs.relative:
        combined = _apply_relative_stack_values(pd, combined, stack_columns)

    row_specs = list(LLAMA_E2E_ROW_ORDER)
    fig, axes = plt.subplots(len(row_specs), 1, figsize=_plot_size(knobs, len(row_specs)), squeeze=False)
    axes_list = list(axes[:, 0])
    palette = _stack_palette(knobs)
    colors = {column: palette[idx % len(palette)] for idx, column in enumerate(stack_columns)}
    candidate_order = {candidate: idx for idx, candidate in enumerate(E2E_CANDIDATE_COLUMNS)}
    legend_handles = None
    legend_labels = None

    for ax, (model_label, stage) in zip(axes_list, row_specs):
        stage_df = combined[
            combined["model"].astype(str).eq(model_label)
            & combined["stage"].astype(str).eq(stage)
        ].copy()
        subplot_title = _format_subplot_title(
            knobs,
            model=model_label,
            stage=stage,
        )
        if knobs.subplot_title_inside:
            ax.text(
                0.01,
                0.96,
                subplot_title,
                transform=ax.transAxes,
                ha="left",
                va="top",
                fontsize=knobs.subplot_title_fontsize,
                fontweight="bold",
                bbox={"facecolor": "white", "edgecolor": "none", "pad": 0.5},
            )
        else:
            ax.set_title(subplot_title, fontsize=knobs.subplot_title_fontsize)
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
        stage_df["__candidate_sort"] = stage_df["candidate"].map(lambda value: candidate_order.get(str(value), len(candidate_order)))
        stage_df = stage_df.sort_values(["__batch_sort", "__seq_sort", "__candidate_sort", "candidate"])

        include_batch = knobs.x_group_axis == "batch"
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

        width = _stage_bar_width(
            knobs,
            stage,
            knobs.bar_width,
            max_width=MAX_BAR_FILL_RATIO,
        )
        bottoms = [0.0 for _ in positions]
        for column in stack_columns:
            values = stage_df[column].tolist()
            ax.bar(
                positions,
                values,
                bottom=bottoms,
                width=width,
                color=colors[column],
                edgecolor=knobs.bar_edgecolor,
                linewidth=knobs.bar_linewidth,
                alpha=knobs.bar_alpha,
                label=column,
            )
            bottoms = [bottom + value for bottom, value in zip(bottoms, values)]
        if knobs.value_labels:
            _add_stacked_total_labels(
                ax,
                positions,
                bottoms,
                knobs,
                bar_width=width,
            )

        if legend_handles is None:
            legend_handles, legend_labels = ax.get_legend_handles_labels()
        ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
        _set_grouped_x_ticks(
            ax,
            stage_df,
            positions,
            include_batch=include_batch,
            knobs=knobs,
        )
        ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
        ax.grid(axis="y", alpha=knobs.grid_alpha)
        ymax = max(bottoms, default=1.0)
        _apply_subplot_x_margin(ax, knobs)
        _apply_y_limits(ax, stage, ymax, knobs)

    _add_top_legend(fig, legend_handles, legend_labels, len(stack_columns), knobs)
    if knobs.title is not None:
        fig.suptitle(knobs.title, fontsize=knobs.title_fontsize, y=knobs.suptitle_y)
    if knobs.x_label:
        fig.supxlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    fig.tight_layout(
        rect=knobs.tight_layout_rect,
        pad=knobs.tight_layout_pad,
        h_pad=knobs.tight_layout_h_pad,
    )
    _save_figure(fig, out_dir / filename, knobs)
    plt.close(fig)


def plot_llama_e2e_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_latency_stacked.png",
        data_label="Llama E2E stacked",
        knobs=knobs,
    )


def plot_llama_e2e_gemm_layout_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_gemm_layout_latency_stacked.png",
        data_label="Llama E2E GEMM + layout stacked",
        knobs=knobs,
        stack_transform=_build_gemm_layout_stack,
    )


def plot_llama_e2e_gemm_layout_vector_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_gemm_layout_vector_latency_stacked.png",
        data_label="Llama E2E GEMM + layout + vector stacked",
        knobs=knobs,
        stack_transform=_build_gemm_layout_vector_stack,
    )


def plot_llama_e2e_no_area_norm_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_e2e_latency_no_area_norm_stacked.png",
        data_label="Llama E2E stacked without area normalization",
        knobs=knobs,
    )


def plot_model_gemm_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_gemm_only_latency.png",
        data_label="Llama GEMM-only",
        knobs=knobs,
    )


def plot_model_gemm_no_area_norm_stacked_bars(
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename="llama_gemm_only_latency_no_area_norm.png",
        data_label="Llama GEMM-only without area normalization",
        knobs=knobs,
    )


def plot_model_gemm_energy_stacked_bars(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    out_dir: Path,
    *,
    knobs: StackedBarKnobs,
    no_area_norm: bool = False,
) -> None:
    suffix = "_no_area_norm" if no_area_norm else ""
    qualifier = " without area normalization" if no_area_norm else ""
    plot_model_stacked_bars(
        model_csvs,
        out_dir,
        filename=f"llama_gemm_only_energy_per_token_{power_metric}{suffix}.png",
        data_label=f"Llama GEMM-only energy{qualifier} ({power_metric})",
        knobs=knobs,
    )


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


def run_llama_e2e_no_area_norm_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    plot_llama_e2e_no_area_norm_bars(
        model_csvs,
        output_root / "llama_e2e_no_area_norm",
        knobs=knobs,
    )


def run_llama_e2e_stacked_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_llama_e2e_stacked_bars(
        model_csvs,
        output_root / "llama_e2e_stacked",
        knobs=knobs,
    )


def run_llama_e2e_gemm_layout_stacked_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_llama_e2e_gemm_layout_stacked_bars(
        model_csvs,
        output_root / "llama_e2e_gemm_layout_stacked",
        knobs=knobs,
    )


def run_llama_e2e_gemm_layout_vector_stacked_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_llama_e2e_gemm_layout_vector_stacked_bars(
        model_csvs,
        output_root / "llama_e2e_gemm_layout_vector_stacked",
        knobs=knobs,
    )


def run_llama_e2e_no_area_norm_stacked_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_llama_e2e_no_area_norm_stacked_bars(
        model_csvs,
        output_root / "llama_e2e_no_area_norm_stacked",
        knobs=knobs,
    )


def run_llama_gemm_only_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_gemm_stacked_bars(
        model_csvs,
        output_root / "llama_gemm_only",
        knobs=knobs,
    )


def run_llama_gemm_only_no_area_norm_plot(
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_gemm_no_area_norm_stacked_bars(
        model_csvs,
        output_root / "llama_gemm_only_no_area_norm",
        knobs=knobs,
    )


def run_llama_gemm_only_energy_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_gemm_energy_stacked_bars(
        power_metric,
        model_csvs,
        output_root / "llama_gemm_only_energy",
        knobs=knobs,
    )


def run_llama_gemm_only_energy_no_area_norm_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_gemm_energy_stacked_bars(
        power_metric,
        model_csvs,
        output_root / "llama_gemm_only_energy_no_area_norm",
        knobs=knobs,
        no_area_norm=True,
    )


def run_llama_energy_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    metric_knobs = copy.deepcopy(knobs)
    if metric_knobs.title is not None:
        metric_knobs.title = f"{metric_knobs.title} ({power_metric})"
    plot_model_wide_candidate_bars(
        model_csvs,
        output_root / "llama_energy",
        filename=f"llama_energy_per_token_{power_metric}.png",
        knobs=metric_knobs,
    )


def run_llama_energy_no_area_norm_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    metric_knobs = copy.deepcopy(knobs)
    if metric_knobs.title is not None:
        metric_knobs.title = (
            f"{metric_knobs.title} without area normalization ({power_metric})"
        )
    plot_model_wide_candidate_bars(
        model_csvs,
        output_root / "llama_energy_no_area_norm",
        filename=f"llama_energy_per_token_{power_metric}_no_area_norm.png",
        knobs=metric_knobs,
    )


def run_llama_energy_stacked_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        output_root / "llama_energy_stacked",
        filename=f"llama_energy_per_token_{power_metric}_stacked.png",
        data_label=f"Llama stacked energy ({power_metric})",
        knobs=knobs,
    )


def run_llama_energy_no_area_norm_stacked_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        output_root / "llama_energy_no_area_norm_stacked",
        filename=f"llama_energy_per_token_{power_metric}_no_area_norm_stacked.png",
        data_label=(
            "Llama stacked energy without area normalization "
            f"({power_metric})"
        ),
        knobs=knobs,
    )


def run_llama_energy_gemm_layout_vector_stacked_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        output_root / "llama_energy_gemm_layout_vector_stacked",
        filename=(
            f"llama_energy_per_token_{power_metric}"
            "_gemm_layout_vector_stacked.png"
        ),
        data_label=(
            "Llama GEMM + layout + vector + dequant stacked energy "
            f"({power_metric})"
        ),
        knobs=knobs,
        stack_transform=_build_gemm_layout_vector_dequant_stack,
    )


def run_llama_energy_no_area_norm_gemm_layout_vector_stacked_plot(
    power_metric: str,
    model_csvs: Sequence[tuple[str, str, Path]],
    output_root: Path,
    *,
    knobs: StackedBarKnobs,
) -> None:
    plot_model_stacked_bars(
        model_csvs,
        output_root / "llama_energy_no_area_norm_gemm_layout_vector_stacked",
        filename=(
            f"llama_energy_per_token_{power_metric}_no_area_norm_"
            "gemm_layout_vector_stacked.png"
        ),
        data_label=(
            "Llama GEMM + layout + vector + dequant stacked energy "
            f"without area normalization ({power_metric})"
        ),
        knobs=knobs,
        stack_transform=_build_gemm_layout_vector_dequant_stack,
    )


def collect_model_csvs(
    *,
    explicit_by_model: dict[str, str | None],
    prepared_root: Path,
    latency_dir: Path,
    kind: str,
    label: str,
) -> list[tuple[str, str, Path]]:
    model_csvs: list[tuple[str, str, Path]] = []
    for model_key, model_label in LLAMA_E2E_MODELS:
        csv_path = model_csv_path(
            explicit=explicit_by_model.get(model_key),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            model_key=model_key,
            kind=kind,
            label=label,
        )
        model_csvs.append((model_key, model_label, csv_path))
    return model_csvs


def _provided_model_inputs(
    explicit_by_model: dict[str, str | None],
) -> dict[str, str]:
    return {
        model_key: path
        for model_key, path in explicit_by_model.items()
        if path is not None
    }


def run_optional_llama_model_plot(
    *,
    selected_plot: str,
    plot_name: str,
    explicit_by_model: dict[str, str | None],
    prepared_root: Path,
    latency_dir: Path,
    output_root: Path,
    kind: str,
    label: str,
    knobs: WideBarKnobs,
    runner: Any,
) -> None:
    required = selected_plot == plot_name or any(explicit_by_model.values())
    try:
        model_csvs = collect_model_csvs(
            explicit_by_model=explicit_by_model,
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            kind=kind,
            label=label,
        )
    except FileNotFoundError as exc:
        if required:
            raise
        print(f"skip {plot_name}: {exc}")
    else:
        runner(model_csvs, output_root, knobs=knobs)


def collect_model_energy_csv_groups(
    *,
    explicit_by_model: dict[str, str | None],
    prepared_root: Path,
    latency_dir: Path,
    kind: str = "energy",
) -> list[tuple[str, list[tuple[str, str, Path]]]]:
    if any(explicit_by_model.values()):
        explicit_paths: dict[str, Path] = {}
        explicit_metrics: set[str] = set()
        for model_key, explicit in explicit_by_model.items():
            if not explicit:
                continue
            csv_path = _prepared_csv_from_path(resolve_under_latency_dir(explicit, latency_dir, prefer_existing=True))
            if not csv_path.exists():
                raise FileNotFoundError(csv_path)
            explicit_paths[model_key] = csv_path
            explicit_metrics.add(_validate_energy_csv_schema(csv_path, kind))
        if len(explicit_metrics) != 1:
            raise ValueError(
                f"explicit {kind} inputs must use one power metric: {sorted(explicit_metrics)}"
            )
        explicit_metric = next(iter(explicit_metrics))
        model_csvs = []
        for model_key, model_label in LLAMA_E2E_MODELS:
            csv_path = explicit_paths.get(model_key)
            if csv_path is None:
                csv_path = model_energy_csv_path(
                    explicit=None,
                    prepared_root=prepared_root,
                    latency_dir=latency_dir,
                    model_key=model_key,
                    power_metric=explicit_metric,
                    kind=kind,
                )
            model_csvs.append((model_key, model_label, csv_path))
        return [(explicit_metric, model_csvs)]

    groups: list[tuple[str, list[tuple[str, str, Path]]]] = []
    missing: list[FileNotFoundError] = []
    for power_metric in ENERGY_POWER_METRICS:
        model_csvs: list[tuple[str, str, Path]] = []
        try:
            for model_key, model_label in LLAMA_E2E_MODELS:
                csv_path = model_energy_csv_path(
                    explicit=None,
                    prepared_root=prepared_root,
                    latency_dir=latency_dir,
                    model_key=model_key,
                    power_metric=power_metric,
                    kind=kind,
                )
                model_csvs.append((model_key, model_label, csv_path))
        except FileNotFoundError as exc:
            missing.append(exc)
            continue
        groups.append((power_metric, model_csvs))
    if not groups and missing:
        raise missing[0]
    for exc in missing:
        print(f"skip llama_{kind} metric: {exc}")
    return groups


def run_auto_discovered_energy_plot(
    *,
    selected_plot: str,
    plot_name: str,
    kind: str,
    prepared_root: Path,
    latency_dir: Path,
    output_root: Path,
    knobs: WideBarKnobs,
    runner: Any,
) -> None:
    explicit_by_model = {
        model_key: None
        for model_key, _model_label in LLAMA_E2E_MODELS
    }
    try:
        model_csv_groups = collect_model_energy_csv_groups(
            explicit_by_model=explicit_by_model,
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            kind=kind,
        )
    except FileNotFoundError as exc:
        if selected_plot == plot_name:
            raise
        print(f"skip {plot_name}: {exc}")
        return

    for power_metric, model_csvs in model_csv_groups:
        runner(
            power_metric,
            model_csvs,
            output_root,
            knobs=knobs,
        )


def configured_raw_db_paths(latency_dir: Path) -> tuple[Path, ...]:
    paths: list[Path] = []
    seen: set[Path] = set()
    for root_name in RAW_DB_ROOT_NAMES:
        for subdir in RAW_DB_SUBDIRS:
            path = (latency_dir / root_name / subdir / "raw_db.csv").resolve()
            if not path.exists() or path in seen:
                continue
            paths.append(path)
            seen.add(path)
    if not paths:
        raise FileNotFoundError(
            f"no configured raw_db.csv files found under {latency_dir}"
        )
    return tuple(paths)


def plot_kernel_dynamic_power_by_kind(
    raw_db_paths: Sequence[Path],
    out_dir: Path,
    *,
    knobs: WideBarKnobs,
) -> None:
    pd, plt = _import_plot_modules()
    frames = []
    required = {"kind", "app", "power_dynamic_avg_w", "status"}
    for path in raw_db_paths:
        frame = pd.read_csv(path, low_memory=False)
        missing = required - set(frame.columns)
        if missing:
            raise ValueError(f"{path} missing columns: {sorted(missing)}")
        frame = frame[["kind", "app", "power_dynamic_avg_w", "status"]].copy()
        frame["source_raw_db"] = str(path)
        frames.append(frame)

    combined = pd.concat(frames, ignore_index=True)
    combined = combined[combined["status"].astype(str).eq("pass")].copy()
    combined["kind"] = combined["kind"].fillna("").astype(str).str.strip()
    combined["power_dynamic_avg_w"] = pd.to_numeric(
        combined["power_dynamic_avg_w"],
        errors="coerce",
    )
    combined = combined[
        combined["kind"].ne("")
        & combined["power_dynamic_avg_w"].map(
            lambda value: math.isfinite(float(value)) if pd.notna(value) else False
        )
    ].copy()
    combined = combined[combined["kind"].ne("layout")].copy()
    if combined.empty:
        raise ValueError("configured raw DBs contain no valid dynamic power rows")

    combined["app"] = combined["app"].fillna("").astype(str).str.strip()
    combined["kernel_group"] = combined["kind"]
    combined["tick_label"] = combined["kind"].map(
        lambda kind: KERNEL_DYNAMIC_POWER_LABELS.get(kind, kind)
    )
    gemm_mask = combined["kind"].eq("gemm")
    unknown_gemm_apps = sorted(
        set(combined.loc[gemm_mask, "app"]) - set(GEMM_DYNAMIC_POWER_LABELS)
    )
    if unknown_gemm_apps:
        raise ValueError(
            f"unsupported GEMM apps in raw DBs: {unknown_gemm_apps}"
        )
    combined.loc[gemm_mask, "kernel_group"] = combined.loc[
        gemm_mask, "app"
    ].map(lambda app: f"gemm::{app}")
    combined.loc[gemm_mask, "tick_label"] = combined.loc[
        gemm_mask, "app"
    ].map(GEMM_DYNAMIC_POWER_LABELS)

    summary = (
        combined.groupby(
            ["kernel_group", "kind", "tick_label"],
            as_index=False,
            sort=False,
        )
        .agg(
            mean_dynamic_power_w=("power_dynamic_avg_w", "mean"),
            std_dynamic_power_w=("power_dynamic_avg_w", "std"),
            measurement_count=("power_dynamic_avg_w", "count"),
        )
    )
    summary["std_dynamic_power_w"] = summary["std_dynamic_power_w"].fillna(0.0)
    reserved_kinds = {"gemm", "quantization", "dequantization"}
    vector_kinds = sorted(set(combined["kind"]) - reserved_kinds)
    group_order = [*vector_kinds]
    group_order.extend(
        kind
        for kind in ("quantization", "dequantization")
        if bool(combined["kind"].eq(kind).any())
    )
    group_order.extend(
        f"gemm::{app}"
        for app in GEMM_DYNAMIC_POWER_LABELS
        if bool((combined["app"].eq(app) & gemm_mask).any())
    )
    group_rank = {group: rank for rank, group in enumerate(group_order)}
    summary["_group_rank"] = summary["kernel_group"].map(group_rank)
    summary = summary.sort_values("_group_rank").drop(columns="_group_rank")
    summary = summary.reset_index(drop=True)

    out_dir.mkdir(parents=True, exist_ok=True)
    summary.to_csv(out_dir / "kernel_dynamic_power_by_kind.csv", index=False)

    positions = list(range(len(summary)))
    means = summary["mean_dynamic_power_w"].tolist()
    stds = summary["std_dynamic_power_w"].tolist()
    fig, ax = plt.subplots(figsize=knobs.figsize)
    ax.bar(
        positions,
        means,
        yerr=stds,
        width=0.72,
        color="#2171B5",
        edgecolor=knobs.bar_edgecolor,
        linewidth=knobs.bar_linewidth,
        alpha=knobs.bar_alpha,
        capsize=2.0,
        error_kw={"elinewidth": 0.6, "capthick": 0.6, "ecolor": "0.2"},
    )
    ax.set_xticks(positions)
    ax.set_xticklabels(
        summary["tick_label"].tolist(),
        rotation=knobs.x_tick_label_rotation,
        ha="right" if knobs.x_tick_label_rotation else "center",
        fontsize=knobs.tick_label_fontsize,
    )
    ax.set_xlabel(knobs.x_label, fontsize=knobs.axis_label_fontsize)
    ax.set_ylabel(knobs.y_label, fontsize=knobs.axis_label_fontsize)
    ax.tick_params(axis="y", labelsize=knobs.tick_label_fontsize)
    ax.grid(axis="y", alpha=knobs.grid_alpha)
    ax.set_axisbelow(True)
    ymax = max(
        (float(mean) + float(std) for mean, std in zip(means, stds)),
        default=1.0,
    )
    _apply_y_limits(ax, "", ymax, knobs)
    if knobs.title is not None:
        ax.set_title(knobs.title, fontsize=knobs.title_fontsize)
    fig.tight_layout(
        rect=knobs.tight_layout_rect,
        pad=knobs.tight_layout_pad,
    )
    _save_figure(fig, out_dir / "kernel_dynamic_power_by_kind.png", knobs)
    plt.close(fig)


def run_selected_plots(args: argparse.Namespace) -> None:
    repo_root = find_repo_root()
    latency_dir = Path(args.latency_dir).expanduser().resolve() if args.latency_dir else repo_root / "analysis_workspace" / "latency_on_hw"
    prepared_root = resolve_under_latency_dir(args.prepared_root, latency_dir)
    output_root = resolve_under_latency_dir(args.out_dir, latency_dir)
    output_root.mkdir(parents=True, exist_ok=True)

    plot = args.plot
    knobs = _plot_knobs_from_args(args)

    if plot in {"kernel_dynamic_power", "all"}:
        raw_db_paths = configured_raw_db_paths(latency_dir)
        print(f"kernel dynamic power raw DBs: {len(raw_db_paths)}")
        plot_kernel_dynamic_power_by_kind(
            raw_db_paths,
            output_root / "kernel_dynamic_power",
            knobs=knobs.kernel_dynamic_power,
        )

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
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_data,
                "llama3_8b": args.llama3_data,
                "llama3p2_1b": args.llama3p2_1b_data,
                "llama3p2_3b": args.llama3p2_3b_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="main_all",
            label="E2E",
            knobs=knobs.llama_e2e,
            runner=run_llama_e2e_plot,
        )

    if plot in {"llama_e2e_no_area_norm", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e_no_area_norm",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_no_area_norm_data,
                "llama3_8b": args.llama3_no_area_norm_data,
                "llama3p2_1b": args.llama3p2_1b_no_area_norm_data,
                "llama3p2_3b": args.llama3p2_3b_no_area_norm_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="e2e_no_area_norm",
            label="E2E without area normalization",
            knobs=knobs.llama_e2e_no_area_norm,
            runner=run_llama_e2e_no_area_norm_plot,
        )

    if plot in {"llama_e2e_no_area_norm_stacked", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e_no_area_norm_stacked",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_no_area_norm_stacked_data,
                "llama3_8b": args.llama3_no_area_norm_stacked_data,
                "llama3p2_1b": args.llama3p2_1b_no_area_norm_stacked_data,
                "llama3p2_3b": args.llama3p2_3b_no_area_norm_stacked_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="e2e_no_area_norm_stacked",
            label="E2E stacked without area normalization",
            knobs=knobs.llama_e2e_no_area_norm_stacked,
            runner=run_llama_e2e_no_area_norm_stacked_plot,
        )

    if plot in {"llama_e2e_gemm_layout_stacked", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e_gemm_layout_stacked",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_e2e_gemm_layout_stacked_data,
                "llama3_8b": args.llama3_e2e_gemm_layout_stacked_data,
                "llama3p2_1b": args.llama3p2_1b_e2e_gemm_layout_stacked_data,
                "llama3p2_3b": args.llama3p2_3b_e2e_gemm_layout_stacked_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="e2e_gemm_layout_stacked",
            label="E2E GEMM + layout stacked",
            knobs=knobs.llama_e2e_gemm_layout_stacked,
            runner=run_llama_e2e_gemm_layout_stacked_plot,
        )

    if plot in {"llama_e2e_gemm_layout_vector_stacked", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e_gemm_layout_vector_stacked",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_e2e_gemm_layout_stacked_data,
                "llama3_8b": args.llama3_e2e_gemm_layout_stacked_data,
                "llama3p2_1b": args.llama3p2_1b_e2e_gemm_layout_stacked_data,
                "llama3p2_3b": args.llama3p2_3b_e2e_gemm_layout_stacked_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="e2e_gemm_layout_stacked",
            label="E2E GEMM + layout + vector stacked",
            knobs=knobs.llama_e2e_gemm_layout_vector_stacked,
            runner=run_llama_e2e_gemm_layout_vector_stacked_plot,
        )

    if plot in {"llama_e2e_stacked", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_e2e_stacked",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_e2e_stacked_data,
                "llama3_8b": args.llama3_e2e_stacked_data,
                "llama3p2_1b": args.llama3p2_1b_e2e_stacked_data,
                "llama3p2_3b": args.llama3p2_3b_e2e_stacked_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="e2e_stacked",
            label="E2E stacked",
            knobs=knobs.llama_e2e_stacked,
            runner=run_llama_e2e_stacked_plot,
        )

    if plot in {"llama_gemm_only", "all"}:
        required = (
            plot == "llama_gemm_only"
            or bool(args.llama2_gemm_data)
            or bool(args.llama3_gemm_data)
            or bool(args.llama3p2_1b_gemm_data)
            or bool(args.llama3p2_3b_gemm_data)
        )
        explicit_by_model = {
            "llama2_7b": args.llama2_gemm_data,
            "llama3_8b": args.llama3_gemm_data,
            "llama3p2_1b": args.llama3p2_1b_gemm_data,
            "llama3p2_3b": args.llama3p2_3b_gemm_data,
        }
        missing_error: Exception | None = None
        try:
            model_csvs = collect_model_csvs(
                explicit_by_model=explicit_by_model,
                prepared_root=prepared_root,
                latency_dir=latency_dir,
                kind="gemm_only",
                label="GEMM-only",
            )
        except FileNotFoundError as exc:
            missing_error = exc

        if missing_error is not None:
            if required:
                raise missing_error
            print(f"skip llama_gemm_only: {missing_error}")
        else:
            run_llama_gemm_only_plot(
                model_csvs,
                output_root,
                knobs=knobs.llama_gemm_only,
            )

    if plot in {"llama_gemm_only_no_area_norm", "all"}:
        run_optional_llama_model_plot(
            selected_plot=plot,
            plot_name="llama_gemm_only_no_area_norm",
            explicit_by_model=_provided_model_inputs({
                "llama2_7b": args.llama2_gemm_no_area_norm_data,
                "llama3_8b": args.llama3_gemm_no_area_norm_data,
                "llama3p2_1b": args.llama3p2_1b_gemm_no_area_norm_data,
                "llama3p2_3b": args.llama3p2_3b_gemm_no_area_norm_data,
            }),
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            kind="gemm_only_no_area_norm",
            label="GEMM-only without area normalization",
            knobs=knobs.llama_gemm_only_no_area_norm,
            runner=run_llama_gemm_only_no_area_norm_plot,
        )

    if plot in {"llama_gemm_only_energy", "all"}:
        required = (
            plot == "llama_gemm_only_energy"
            or bool(args.llama2_gemm_energy_data)
            or bool(args.llama3_gemm_energy_data)
            or bool(args.llama3p2_1b_gemm_energy_data)
            or bool(args.llama3p2_3b_gemm_energy_data)
        )
        explicit_by_model = {
            "llama2_7b": args.llama2_gemm_energy_data,
            "llama3_8b": args.llama3_gemm_energy_data,
            "llama3p2_1b": args.llama3p2_1b_gemm_energy_data,
            "llama3p2_3b": args.llama3p2_3b_gemm_energy_data,
        }
        missing_error: Exception | None = None
        try:
            model_csv_groups = collect_model_energy_csv_groups(
                explicit_by_model=explicit_by_model,
                prepared_root=prepared_root,
                latency_dir=latency_dir,
                kind="gemm_only_energy",
            )
        except FileNotFoundError as exc:
            missing_error = exc

        if missing_error is not None:
            if required:
                raise missing_error
            print(f"skip llama_gemm_only_energy: {missing_error}")
        else:
            for power_metric, model_csvs in model_csv_groups:
                run_llama_gemm_only_energy_plot(
                    power_metric,
                    model_csvs,
                    output_root,
                    knobs=knobs.llama_gemm_only_energy,
                )

    if plot in {"llama_energy", "all"}:
        required = (
            plot == "llama_energy"
            or bool(args.llama2_energy_data)
            or bool(args.llama3_energy_data)
            or bool(args.llama3p2_1b_energy_data)
            or bool(args.llama3p2_3b_energy_data)
        )
        explicit_by_model = {
            "llama2_7b": args.llama2_energy_data,
            "llama3_8b": args.llama3_energy_data,
            "llama3p2_1b": args.llama3p2_1b_energy_data,
            "llama3p2_3b": args.llama3p2_3b_energy_data,
        }
        missing_error: Exception | None = None
        try:
            model_csv_groups = collect_model_energy_csv_groups(
                explicit_by_model=explicit_by_model,
                prepared_root=prepared_root,
                latency_dir=latency_dir,
            )
        except FileNotFoundError as exc:
            missing_error = exc

        if missing_error is not None:
            if required:
                raise missing_error
            print(f"skip llama_energy: {missing_error}")
        else:
            for power_metric, model_csvs in model_csv_groups:
                run_llama_energy_plot(
                    power_metric,
                    model_csvs,
                    output_root,
                    knobs=knobs.llama_energy,
                )

    if plot in {"llama_energy_stacked", "all"}:
        required = (
            plot == "llama_energy_stacked"
            or bool(args.llama2_energy_stacked_data)
            or bool(args.llama3_energy_stacked_data)
            or bool(args.llama3p2_1b_energy_stacked_data)
            or bool(args.llama3p2_3b_energy_stacked_data)
        )
        explicit_by_model = {
            "llama2_7b": args.llama2_energy_stacked_data,
            "llama3_8b": args.llama3_energy_stacked_data,
            "llama3p2_1b": args.llama3p2_1b_energy_stacked_data,
            "llama3p2_3b": args.llama3p2_3b_energy_stacked_data,
        }
        missing_error: Exception | None = None
        try:
            model_csv_groups = collect_model_energy_csv_groups(
                explicit_by_model=explicit_by_model,
                prepared_root=prepared_root,
                latency_dir=latency_dir,
                kind="energy_stacked",
            )
        except FileNotFoundError as exc:
            missing_error = exc

        if missing_error is not None:
            if required:
                raise missing_error
            print(f"skip llama_energy_stacked: {missing_error}")
        else:
            for power_metric, model_csvs in model_csv_groups:
                run_llama_energy_stacked_plot(
                    power_metric,
                    model_csvs,
                    output_root,
                    knobs=knobs.llama_energy_stacked,
                )

    if plot in {"llama_energy_gemm_layout_vector_stacked", "all"}:
        required = (
            plot == "llama_energy_gemm_layout_vector_stacked"
            or bool(args.llama2_energy_gemm_layout_vector_stacked_data)
            or bool(args.llama3_energy_gemm_layout_vector_stacked_data)
            or bool(args.llama3p2_1b_energy_gemm_layout_vector_stacked_data)
            or bool(args.llama3p2_3b_energy_gemm_layout_vector_stacked_data)
        )
        explicit_by_model = {
            "llama2_7b": args.llama2_energy_gemm_layout_vector_stacked_data,
            "llama3_8b": args.llama3_energy_gemm_layout_vector_stacked_data,
            "llama3p2_1b": (
                args.llama3p2_1b_energy_gemm_layout_vector_stacked_data
            ),
            "llama3p2_3b": (
                args.llama3p2_3b_energy_gemm_layout_vector_stacked_data
            ),
        }
        missing_error: Exception | None = None
        try:
            model_csv_groups = collect_model_energy_csv_groups(
                explicit_by_model=explicit_by_model,
                prepared_root=prepared_root,
                latency_dir=latency_dir,
                kind="energy_gemm_layout_vector_stacked",
            )
        except FileNotFoundError as exc:
            missing_error = exc

        if missing_error is not None:
            if required:
                raise missing_error
            print(
                "skip llama_energy_gemm_layout_vector_stacked: "
                f"{missing_error}"
            )
        else:
            for power_metric, model_csvs in model_csv_groups:
                run_llama_energy_gemm_layout_vector_stacked_plot(
                    power_metric,
                    model_csvs,
                    output_root,
                    knobs=knobs.llama_energy_gemm_layout_vector_stacked,
                )

    if plot in {"llama_gemm_only_energy_no_area_norm", "all"}:
        run_auto_discovered_energy_plot(
            selected_plot=plot,
            plot_name="llama_gemm_only_energy_no_area_norm",
            kind="gemm_only_energy_no_area_norm",
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            knobs=knobs.llama_gemm_only_energy_no_area_norm,
            runner=run_llama_gemm_only_energy_no_area_norm_plot,
        )

    if plot in {"llama_energy_no_area_norm", "all"}:
        run_auto_discovered_energy_plot(
            selected_plot=plot,
            plot_name="llama_energy_no_area_norm",
            kind="energy_no_area_norm",
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            knobs=knobs.llama_energy_no_area_norm,
            runner=run_llama_energy_no_area_norm_plot,
        )

    if plot in {"llama_energy_no_area_norm_stacked", "all"}:
        run_auto_discovered_energy_plot(
            selected_plot=plot,
            plot_name="llama_energy_no_area_norm_stacked",
            kind="energy_no_area_norm_stacked",
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            knobs=knobs.llama_energy_no_area_norm_stacked,
            runner=run_llama_energy_no_area_norm_stacked_plot,
        )

    if plot in {
        "llama_energy_no_area_norm_gemm_layout_vector_stacked",
        "all",
    }:
        run_auto_discovered_energy_plot(
            selected_plot=plot,
            plot_name="llama_energy_no_area_norm_gemm_layout_vector_stacked",
            kind="energy_no_area_norm_gemm_layout_vector_stacked",
            prepared_root=prepared_root,
            latency_dir=latency_dir,
            output_root=output_root,
            knobs=knobs.llama_energy_no_area_norm_gemm_layout_vector_stacked,
            runner=(
                run_llama_energy_no_area_norm_gemm_layout_vector_stacked_plot
            ),
        )


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    run_selected_plots(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
