#!/usr/bin/env python3
"""Prepare plot-ready CSVs from a complete compose result.

Example from the repository root::

    conda run -n vortex python analysis_workspace/latency_on_hw/prepare.py \
      --composed-csv analysis_workspace/latency_on_hw/composed_results/combined/composed.csv \
      --out-tokens 128 \
      --workers 4

The input may contain several decode output lengths.  One invocation selects
exactly one scalar ``out_tokens`` workload, reports decode latency as average
TPOT, and reports energy per generated token.  Measurement reuse and
interpolation must already be resolved by ``run_compose.py``.
"""

import argparse
from dataclasses import dataclass, replace
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace
import math
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import pandas as pd


def find_repo_root(start: Path | None = None) -> Path:
    path = Path.cwd() if start is None else start
    for candidate in (path.resolve(), *path.resolve().parents):
        if (candidate / "tools" / "latency_bench").is_dir():
            return candidate
    raise RuntimeError("failed to find Vortex repository root")


REPO_ROOT = find_repo_root()
LATENCY_DIR = REPO_ROOT / "analysis_workspace" / "latency_on_hw"
for path in (REPO_ROOT, LATENCY_DIR):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import tools.latency_bench.plot as latency_plot_module
from tools.latency_bench.compose import LatencyScaleRule, apply_latency_scale_rules
from tools.latency_bench.plot import SuiteBarPlotOptions, prepare_suite_bar_data_versions
from tools.latency_bench.suite import SuiteMatrixOverrides, load_suite
from energy_per_token import (
    DEFAULT_FPGA_PERIOD_S,
    _fpga_period_s as resolve_energy_fpga_period_s,
    add_relative_energy_component_values,
    add_relative_energy_values,
    energy_rows_from_records,
    summarize_energy_rows,
)
import plot as plot_script

FPGA_IDLE_POWER = 0.854 * 6.300 + 0.852 * 0.200

OUTPUT_FOLDER = "output_figure"

# Main workload selection. Use a string for one model or a list/tuple for
# multiple models.
# TARGET_MODEL = ["llama2_7b", "llama3_8b", "llama3p2_1b", "llama3p2_3b"]
TARGET_MODEL = ["llama2_7b", "llama3_8b"]


def target_models() -> tuple[str, ...]:
    if isinstance(TARGET_MODEL, str):
        models = (TARGET_MODEL,)
    else:
        models = tuple(TARGET_MODEL)
    if not models:
        raise ValueError("TARGET_MODEL must contain at least one model")
    return models


TARGET_MODELS = target_models()

# Match make_case.sh / make_cases.sh stage-specific shape controls:
# --prefill-batches, --prefill-seq-lens, --generation-batches, --generation-seq-lens.
TARGET_PREFILL_BATCHES = (1,)
# TARGET_PREFILL_SEQ_LENS = (1024,)
TARGET_PREFILL_SEQ_LENS = (1024, 2048, 4096, 8192, 16384, 32768)
# TARGET_GENERATION_BATCHES = (1,)
TARGET_GENERATION_BATCHES = (1,2,4)
# TARGET_GENERATION_SEQ_LENS = (1024,)
TARGET_GENERATION_SEQ_LENS = (1024, 2048, 4096, 8192, 16384, 32768)
# make_case.sh quick generates decode steps 1..128 from gen_kv_len=1024.
TARGET_GENERATION_OUT_TOKENS = 128
TARGET_GENERATION_MAX_SEQ_LEN = 65536
TARGET_GENERATION_DECODE_MEASUREMENT = "sampled"
TARGET_GENERATION_DECODE_SAMPLE_INTERVAL = 32

# Per-output shape selection. Empty tuples mean "all available shapes" for that stage.
E2E_PREFILL_BATCHES = TARGET_PREFILL_BATCHES
E2E_PREFILL_SEQ_LENS = TARGET_PREFILL_SEQ_LENS
E2E_GENERATION_BATCHES = TARGET_GENERATION_BATCHES
E2E_GENERATION_SEQ_LENS = TARGET_GENERATION_SEQ_LENS

GEMM_ONLY_PREFILL_BATCHES = TARGET_PREFILL_BATCHES
GEMM_ONLY_PREFILL_SEQ_LENS = TARGET_PREFILL_SEQ_LENS
GEMM_ONLY_GENERATION_BATCHES = TARGET_GENERATION_BATCHES
GEMM_ONLY_GENERATION_SEQ_LENS = TARGET_GENERATION_SEQ_LENS

ENERGY_PREFILL_BATCHES = TARGET_PREFILL_BATCHES
ENERGY_PREFILL_SEQ_LENS = TARGET_PREFILL_SEQ_LENS
ENERGY_GENERATION_BATCHES = TARGET_GENERATION_BATCHES
ENERGY_GENERATION_SEQ_LENS = TARGET_GENERATION_SEQ_LENS
E2E_GENERATION_OUT_TOKENS = TARGET_GENERATION_OUT_TOKENS
GEMM_ONLY_GENERATION_OUT_TOKENS = TARGET_GENERATION_OUT_TOKENS
ENERGY_GENERATION_OUT_TOKENS = TARGET_GENERATION_OUT_TOKENS

# SUITE_SOURCE selects which suite directory is loaded. E2E composition must use
# the original model suites. generated_merged suites are execution shards from
# make_case.sh; merge-suites drops duplicate executions, so they are incomplete
# for model-level totals.
SUITE_SOURCE = "model"  # model or generated_merged_debug


def suite_tag_for_model(model: str) -> str:
    return model if SUITE_SOURCE == "model" else f"{model}_main"


def _stage_shape_name(
    *,
    prefill_batches: tuple[int, ...],
    prefill_seq_lens: tuple[int, ...],
    generation_batches: tuple[int, ...],
    generation_seq_lens: tuple[int, ...],
    generation_out_tokens: int,
) -> str:
    def _shape_name(batches: tuple[int, ...], seq_lens: tuple[int, ...]) -> str:
        batch_text = "all" if not batches else "-".join(str(value) for value in batches)
        seq_text = "all" if not seq_lens else "-".join(str(value) for value in seq_lens)
        return f"b{batch_text}_s{seq_text}"

    prefill = _shape_name(prefill_batches, prefill_seq_lens)
    generation = _shape_name(generation_batches, generation_seq_lens)
    generation = f"{generation}_o{generation_out_tokens}"
    return f"prefill_{prefill}__generation_{generation}"


ShapeSelection = tuple[
    tuple[int, ...],
    tuple[int, ...],
    tuple[int, ...],
    tuple[int, ...],
    int,
]


def _selection_tuple(
    *,
    prefill_batches: tuple[int, ...],
    prefill_seq_lens: tuple[int, ...],
    generation_batches: tuple[int, ...],
    generation_seq_lens: tuple[int, ...],
    generation_out_tokens: int,
) -> ShapeSelection:
    return (
        prefill_batches,
        prefill_seq_lens,
        generation_batches,
        generation_seq_lens,
        generation_out_tokens,
    )


def _stage_shape_name_for_selection(selection: ShapeSelection) -> str:
    (
        prefill_batches,
        prefill_seq_lens,
        generation_batches,
        generation_seq_lens,
        generation_out_tokens,
    ) = selection
    return _stage_shape_name(
        prefill_batches=prefill_batches,
        prefill_seq_lens=prefill_seq_lens,
        generation_batches=generation_batches,
        generation_seq_lens=generation_seq_lens,
        generation_out_tokens=generation_out_tokens,
    )


E2E_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=E2E_PREFILL_BATCHES,
    prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
    generation_batches=E2E_GENERATION_BATCHES,
    generation_seq_lens=E2E_GENERATION_SEQ_LENS,
    generation_out_tokens=E2E_GENERATION_OUT_TOKENS,
)
GEMM_ONLY_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
    prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
    generation_batches=GEMM_ONLY_GENERATION_BATCHES,
    generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
    generation_out_tokens=GEMM_ONLY_GENERATION_OUT_TOKENS,
)
ENERGY_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=ENERGY_PREFILL_BATCHES,
    prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
    generation_batches=ENERGY_GENERATION_BATCHES,
    generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
    generation_out_tokens=ENERGY_GENERATION_OUT_TOKENS,
)
ENERGY_OUTPUT_TAG = "dequant_pure"


def main_out_name(model: str) -> str:
    return f"{model}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_no_area_norm_out_name(model: str) -> str:
    return f"{model}_e2e_no_area_norm_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_stacked_out_name(model: str) -> str:
    return f"{model}_e2e_stacked_by_{E2E_STACK_BY}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_gemm_layout_stacked_out_name(model: str) -> str:
    return f"{model}_e2e_gemm_layout_stacked_by_name_backend_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_no_area_norm_stacked_out_name(model: str) -> str:
    return f"{model}_e2e_no_area_norm_stacked_by_{E2E_STACK_BY}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def gemm_only_out_name(model: str) -> str:
    return f"{model}_gemm_only_{_stage_shape_name_for_selection(GEMM_ONLY_SHAPE_SELECTION)}"


def gemm_only_no_area_norm_out_name(model: str) -> str:
    return (
        f"{model}_gemm_only_no_area_norm_"
        f"{_stage_shape_name_for_selection(GEMM_ONLY_SHAPE_SELECTION)}"
    )


def gemm_only_energy_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_gemm_only_energy_per_token_stacked_by_name_{power_metric}_"
        f"{_stage_shape_name_for_selection(GEMM_ONLY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def gemm_only_energy_no_area_norm_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_gemm_only_energy_per_token_no_area_norm_stacked_by_name_"
        f"{power_metric}_{_stage_shape_name_for_selection(GEMM_ONLY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_energy_per_token_{power_metric}_"
        f"{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_stacked_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_energy_per_token_stacked_by_{E2E_STACK_BY}_{power_metric}_"
        f"{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_gemm_layout_vector_stacked_out_name(
    model: str,
    power_metric: str,
) -> str:
    return (
        f"{model}_energy_per_token_gemm_layout_vector_stacked_by_name_backend_"
        f"{power_metric}_{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_no_area_norm_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_energy_per_token_no_area_norm_{power_metric}_"
        f"{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_no_area_norm_stacked_out_name(model: str, power_metric: str) -> str:
    return (
        f"{model}_energy_per_token_no_area_norm_stacked_by_{E2E_STACK_BY}_"
        f"{power_metric}_{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )


def energy_no_area_norm_gemm_layout_vector_stacked_out_name(
    model: str,
    power_metric: str,
) -> str:
    return (
        f"{model}_energy_per_token_no_area_norm_"
        "gemm_layout_vector_stacked_by_name_backend_"
        f"{power_metric}_{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}_"
        f"{ENERGY_OUTPUT_TAG}"
    )

RAW_DB_SUBDIRS = (
    "C1",
    "C3",
    "C4",
)
RAW_DB_ROOTS = {
    "llama2_7b": LATENCY_DIR / "outputs_llama2_main",
    "llama3_8b": LATENCY_DIR / "outputs_llama3_main",
    "llama3p2_1b": LATENCY_DIR / "outputs_llama3p2_1b_main",
    "llama3p2_3b": LATENCY_DIR / "outputs_llama3p2_3b_main",
}


def raw_dbs_for_model(model: str) -> tuple[Path, ...]:
    try:
        root = RAW_DB_ROOTS[model]
    except KeyError as exc:
        raise ValueError(f"no raw DB root configured for model: {model}") from exc
    return tuple(root / subdir / "raw_db.csv" for subdir in RAW_DB_SUBDIRS)


@lru_cache(maxsize=None)
def raw_measurement_settings(model: str) -> tuple[int, int]:
    frames = []
    for path in raw_dbs_for_model(model):
        frame = pd.read_csv(
            path,
            usecols=lambda column: column in {"status", "warmup", "iterations"},
        )
        if "status" in frame:
            frame = frame[frame["status"].astype(str).eq("pass")]
        frames.append(frame[["warmup", "iterations"]])
    settings = pd.concat(frames, ignore_index=True).apply(
        pd.to_numeric, errors="coerce"
    ).dropna()
    if settings.empty:
        raise ValueError(f"no passing raw measurement settings found for {model}")
    counts = settings.value_counts(sort=True)
    warmup, iterations = counts.index[0]
    return int(warmup), int(iterations)

SUITE_CASE_SUFFIXES = (
    "prefill_C1",
    "prefill_C2",
    "prefill_C3",
    "prefill_C4_alone",
    "prefill_C4_fused",
    "generation_C1",
    "generation_C2",
    "generation_C3",
    "generation_C4_alone",
    "generation_C4_fused",
)


def suite_file_order(model: str) -> list[str]:
    return [f"{model}_{suffix}.yaml" for suffix in SUITE_CASE_SUFFIXES]


def _generated_suite_files(directory: Path) -> list[Path]:
    return [path for path in sorted(directory.glob("*.yaml")) if path.name != "index.yaml"]


def suite_paths(tag: str, model: str) -> list[Path]:
    if SUITE_SOURCE == "model":
        return [LATENCY_DIR / "suites" / tag / filename for filename in suite_file_order(model)]
    if SUITE_SOURCE == "generated_merged_debug":
        base = LATENCY_DIR / "generated_suites" / tag
        return [
            *_generated_suite_files(base / "prefill_merged"),
            *_generated_suite_files(base / "generation_merged"),
        ]
    raise ValueError(f"unsupported SUITE_SOURCE: {SUITE_SOURCE}")


def matrix_overrides_for_selection(selection: ShapeSelection | None) -> SuiteMatrixOverrides | None:
    if selection is None:
        return None
    (
        prefill_batches,
        prefill_seq_lens,
        generation_batches,
        generation_seq_lens,
        generation_out_tokens,
    ) = selection
    return SuiteMatrixOverrides(
        prefill_batch_values=prefill_batches,
        prefill_seq_len_values=prefill_seq_lens,
        generation_batch_values=generation_batches,
        generation_seq_len_values=generation_seq_lens,
        generation_out_token_values=(generation_out_tokens,),
        generation_max_seq_len=TARGET_GENERATION_MAX_SEQ_LEN,
        generation_decode_measurement=TARGET_GENERATION_DECODE_MEASUREMENT,
        generation_decode_sample_interval=TARGET_GENERATION_DECODE_SAMPLE_INTERVAL,
    )


def load_suites(tag: str, *, model: str, shape_selection: ShapeSelection | None = None) -> list:
    matrix_overrides = matrix_overrides_for_selection(shape_selection)
    warmup, iterations = raw_measurement_settings(model)
    return [
        load_suite(
            path,
            repo_root=REPO_ROOT,
            warmup_override=warmup,
            iterations_override=iterations,
            matrix_overrides=matrix_overrides,
        )
        for path in suite_paths(tag, model)
    ]


# Prepared CSV controls. The expensive compose/estimate step writes excel_figure_data.csv and total.csv.
FIGURE_OUTPUT_ROOT = LATENCY_DIR / OUTPUT_FOLDER / "figures_prepare"
FIGURE_DATA_CSV_NAME = "excel_figure_data.csv"
TOTAL_CSV_NAME = "total.csv"
COMPOSED_INPUT: pd.DataFrame | None = None
_PREPARED_ROW_CACHE: dict[tuple, pd.DataFrame] = {}
USE_FIGURE_DATA_CACHE = True
FORCE_REBUILD_FIGURE_DATA = True

# Measurement and aggregation controls.
# Cycle-derived latency is recorded in microseconds by compose.py.
METRIC = "fpga_cycle_latency"
SELECT = "latest"
MISSING = "nan"  # Keep genuinely unresolved measurements visible.
X_AXIS = "seq_len"
HUE_AXIS = "variant"
ROW_AXIS = "stage"
COL_AXIS = "batch"
STACK_BY = "name"
E2E_STACK_BY = "kind"
RELATIVE = True
RELATIVE_SCOPE = "x_tick"  # global, subplot, or x_tick

# Dequantization policy is controlled independently by metric and stage.
# Latency excludes all dequantization. Energy prefill retains only weight
# dequantization, while energy generation includes weight and KV components.
INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_PREFILL = False
INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_PREFILL = False
INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_GENERATION = False
INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_GENERATION = False

INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_PREFILL = True
INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_PREFILL = False
INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_GENERATION = True
INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_GENERATION = True
# Whether the C4-alone variant is included in generated plots and totals.
INCLUDE_C4_ALONE = False

# Optional row filters are applied after compose/estimate and before aggregation.
# Examples:
# PLOT_ROW_FILTERS = (lambda df: df["kind"].eq("gemm"),)
# PLOT_ROW_FILTERS = (lambda df: df["backend"].eq("sgemm_tcu"),)
C4_ALONE_VARIANT = "all_fpint_gemm_improve_alone_layout_spinquant"
C4_FUSED_VARIANT = "all_fpint_gemm_improve_fused_layout_spinquant"


def _stage_shape_mask(
    df: pd.DataFrame,
    *,
    stage: str,
    batches: tuple[int, ...],
    seq_lens: tuple[int, ...],
    out_tokens: int | None = None,
) -> pd.Series:
    mask = df["stage"].astype(str).eq(stage)
    if batches:
        mask &= pd.to_numeric(df["batch"], errors="coerce").isin(batches)
    if seq_lens:
        mask &= pd.to_numeric(df["seq_len"], errors="coerce").isin(seq_lens)
    if out_tokens is not None:
        mask &= pd.to_numeric(df["out_tokens"], errors="coerce").eq(out_tokens)
    return mask


def _target_shape_filter(
    *,
    prefill_batches: tuple[int, ...],
    prefill_seq_lens: tuple[int, ...],
    generation_batches: tuple[int, ...],
    generation_seq_lens: tuple[int, ...],
    generation_out_tokens: int,
):
    def _filter(df: pd.DataFrame) -> pd.Series:
        return _stage_shape_mask(
            df,
            stage="prefill",
            batches=prefill_batches,
            seq_lens=prefill_seq_lens,
        ) | _stage_shape_mask(
            df,
            stage="generation",
            batches=generation_batches,
            seq_lens=generation_seq_lens,
            out_tokens=generation_out_tokens,
        )

    return _filter


E2E_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=E2E_PREFILL_BATCHES,
    prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
    generation_batches=E2E_GENERATION_BATCHES,
    generation_seq_lens=E2E_GENERATION_SEQ_LENS,
    generation_out_tokens=E2E_GENERATION_OUT_TOKENS,
)
GEMM_ONLY_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
    prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
    generation_batches=GEMM_ONLY_GENERATION_BATCHES,
    generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
    generation_out_tokens=GEMM_ONLY_GENERATION_OUT_TOKENS,
)
ENERGY_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=ENERGY_PREFILL_BATCHES,
    prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
    generation_batches=ENERGY_GENERATION_BATCHES,
    generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
    generation_out_tokens=ENERGY_GENERATION_OUT_TOKENS,
)


def _dequantization_stage_filter(
    df: pd.DataFrame,
    *,
    include_weight_prefill: bool,
    include_kv_prefill: bool,
    include_weight_generation: bool,
    include_kv_generation: bool,
) -> pd.Series:
    kind = df["kind"].astype(str)
    stage = df["stage"].astype(str)
    dequantization = kind.eq("dequantization")
    if "name" not in df.columns:
        raise ValueError("dequantization filtering requires a name column")
    name = df["name"].fillna("").astype(str)
    weight_dequantization = dequantization & name.str.contains(
        "_weight_",
        regex=False,
    )
    kv_dequantization = dequantization & name.str.startswith("kv_cache_dequant_")
    unknown_dequantization = dequantization & ~(
        weight_dequantization | kv_dequantization
    )
    if bool(unknown_dequantization.any()):
        unknown_names = sorted(name[unknown_dequantization].unique())
        raise ValueError(
            f"unclassified dequantization kernel names: {unknown_names}"
        )

    keep = ~dequantization
    if include_weight_prefill:
        keep |= weight_dequantization & stage.eq("prefill")
    if include_kv_prefill:
        keep |= kv_dequantization & stage.eq("prefill")
    if include_weight_generation:
        keep |= weight_dequantization & stage.eq("generation")
    if include_kv_generation:
        keep |= kv_dequantization & stage.eq("generation")
    return keep


def filter_latency_dequantization_kernels(df: pd.DataFrame) -> pd.Series:
    return _dequantization_stage_filter(
        df,
        include_weight_prefill=(
            INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_PREFILL
        ),
        include_kv_prefill=INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_PREFILL,
        include_weight_generation=(
            INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_GENERATION
        ),
        include_kv_generation=INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_GENERATION,
    )


def filter_energy_dequantization_kernels(df: pd.DataFrame) -> pd.Series:
    return _dequantization_stage_filter(
        df,
        include_weight_prefill=INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_PREFILL,
        include_kv_prefill=INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_PREFILL,
        include_weight_generation=(
            INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_GENERATION
        ),
        include_kv_generation=INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_GENERATION,
    )


def split_energy_dequantization_kinds(rows: list[dict]) -> None:
    """Split energy-only kind stacks into weight and KV dequantization."""
    for row in rows:
        if str(row.get("kind", "")) != "dequantization":
            continue
        name = str(row.get("name", ""))
        if "_weight_" in name:
            row["kind"] = "W dequant"
        elif name.startswith("kv_cache_dequant_"):
            row["kind"] = "KV dequant"
        else:
            raise ValueError(f"unclassified dequantization kernel name: {name!r}")


LATENCY_DEQUANTIZATION_POLICY = (
    INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_PREFILL,
    INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_PREFILL,
    INCLUDE_WEIGHT_DEQUANTIZATION_IN_LATENCY_GENERATION,
    INCLUDE_KV_DEQUANTIZATION_IN_LATENCY_GENERATION,
)
ENERGY_DEQUANTIZATION_POLICY = (
    INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_PREFILL,
    INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_PREFILL,
    INCLUDE_WEIGHT_DEQUANTIZATION_IN_ENERGY_GENERATION,
    INCLUDE_KV_DEQUANTIZATION_IN_ENERGY_GENERATION,
)


LATENCY_DEQUANTIZATION_FILTERS = (
    ()
    if all(LATENCY_DEQUANTIZATION_POLICY)
    else (filter_latency_dequantization_kernels,)
)
ENERGY_DEQUANTIZATION_FILTERS = (
    ()
    if all(ENERGY_DEQUANTIZATION_POLICY)
    else (filter_energy_dequantization_kernels,)
)
PLOT_ROW_FILTERS = (E2E_SHAPE_FILTER, *LATENCY_DEQUANTIZATION_FILTERS)


def _apply_global_row_filters(row_filters: tuple | None) -> tuple:
    return tuple(PLOT_ROW_FILTERS if row_filters is None else row_filters)


def exclude_c4_alone(df):
    return df["variant"].ne(C4_ALONE_VARIANT)


C4_ALONE_FILTERS = () if INCLUDE_C4_ALONE else (exclude_c4_alone,)


# Display labels and order are part of the prepared Excel-facing CSV schema.
LABEL_MAPS = {
    "stage": {"prefill": "Prefill", "generation": "Generation"},
    "seq_len": {
        64: "64",
        128: "128",
        512: "512",
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


def plot_label_maps(*, include_c4_alone: bool) -> dict:
    label_maps = {axis: dict(mapping) for axis, mapping in LABEL_MAPS.items()}
    if not include_c4_alone:
        label_maps["variant"][C4_FUSED_VARIANT] = "C4"
    return label_maps


# Optional raw DB latency normalization rules. These match raw DB rows before
# compose maps measurements back to suite cases.
LATENCY_SCALE_RULES = []

# Target-case area normalization rules. These match composed suite-case columns
# after raw measurements are mapped back to C1/C2/C3/C4 variants.
# TH16_FP_TCU_CELL_AREA=276593.0284
# TH32_FP_TCU_CELL_AREA=547111.5339
# FPINT_MXU_CELL_AREA=693436.0606
# C1_CELL_AREA = {
#     "tcu":TH32_FP_TCU_CELL_AREA
# }
# C2_CELL_AREA = {
#   "dma_node":275297.9538,
#   "ldma":51471.6923*3+28456.6227,
#   "mem_split" : 18339.1647*3,
#   "tcu" : TH32_FP_TCU_CELL_AREA,
#   "mxu" : FPINT_MXU_CELL_AREA
# }
# C3_CELL_AREA = {
#     "dma_node":275297.9538,
#     "ldma":51471.6923*3+28456.6227,
#     "mem_split" : 18339.1647*3,
#     "mxu" : FPINT_MXU_CELL_AREA
# }
# C4_CELL_AREA = {
#     "dma_engine":262747.8322,
#     "ldma" : 30213.8456*4,
#     "arbiters":3196.3230+4162.9771+4162.9771+4162.9771+4162.9771,
#     "mxu" : FPINT_MXU_CELL_AREA
# }

# naive with ACC MEM version, 2MB version
C1_CELL_AREA = {
    "top": 10.1331,
}
C2_CELL_AREA = {
  "top":12.0691,
}
C3_CELL_AREA = {
  "top":11.5220
}
C4_CELL_AREA = {
  "top":11.2137
}

# AREA_RATIO=FPINT_MXU_CELL_AREA / TH32_FP_TCU_CELL_AREA
# CASE_LATENCY_SCALE_RULES = [
#     # C1 GEMM scale is 1.0, so no rule is needed.
#     LatencyScaleRule(
#         "C2_gemm_area_norm",
#         {"kind": "gemm", "variant": "attn_sgemm_tcu_fpint_gemm_naive_spinquant"},
#         1+AREA_RATIO,
#     ),
#     LatencyScaleRule(
#         "C3_gemm_area_norm",
#         {"kind": "gemm", "variant": "all_fpint_gemm_naive_spinquant"},
#         AREA_RATIO,
#     ),
#     LatencyScaleRule(
#         "C4_gemm_area_norm",
#         {"kind": "gemm", "variant": (C4_ALONE_VARIANT, C4_FUSED_VARIANT)},
#         AREA_RATIO,
#     ),
# ]
CASE_LATENCY_SCALE_RULES = [
    # C1 GEMM scale is 1.0, so no rule is needed.
    LatencyScaleRule(
        "C1_area_norm",
        {"variant": "all_sgemm_tcu_spinquant"},
        sum(C1_CELL_AREA.values()),
    ),
    LatencyScaleRule(
        "C2_area_norm",
        {"variant": "attn_sgemm_tcu_fpint_gemm_naive_spinquant"},
        sum(C2_CELL_AREA.values()),
    ),
    LatencyScaleRule(
        "C3_area_norm",
        {"variant": "all_fpint_gemm_naive_spinquant"},
        sum(C3_CELL_AREA.values()),
    ),
    LatencyScaleRule(
        "C4_area_norm",
        {"variant": (C4_ALONE_VARIANT, C4_FUSED_VARIANT)},
        sum(C4_CELL_AREA.values()),
    ),
]

@dataclass
class PlotRunResult:
    tag: str
    out_dir: Path
    suites: list
    options: SuiteBarPlotOptions | None
    versions: object | None
    composed: object | None
    plot_data: object | None
    stack_data: object | None
    figure_data: pd.DataFrame
    total_csv_path: Path | None = None
    cache_status: str = "unknown"


def figure_data_path(out_name: str) -> Path:
    return FIGURE_OUTPUT_ROOT / out_name / FIGURE_DATA_CSV_NAME


def total_data_path(out_name: str) -> Path:
    return FIGURE_OUTPUT_ROOT / out_name / TOTAL_CSV_NAME


def _read_figure_data(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, keep_default_na=False)


def _write_latency_figure_data(result: PlotRunResult) -> Path:
    deps = SimpleNamespace(latency_plot_module=latency_plot_module)
    path = plot_script.write_latency_figure_data_csv(deps, result)
    _annotate_prepared_csv(path)
    return path


def _annotate_prepared_csv(path: Path) -> None:
    frame = pd.read_csv(path)
    if "out_tokens" in frame.columns:
        frame["out_tokens"] = TARGET_GENERATION_OUT_TOKENS
    else:
        frame.insert(0, "out_tokens", TARGET_GENERATION_OUT_TOKENS)
    frame.to_csv(path, index=False)


def _join_unique(values) -> str:
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        if pd.isna(value):
            continue
        text = str(value)
        if not text or text == "nan":
            continue
        for part in text.split(";"):
            item = part.strip()
            if not item or item in seen:
                continue
            seen.add(item)
            out.append(item)
    return ";".join(out)


def _status_case_ids(frame: pd.DataFrame, statuses: set[str]) -> str:
    if "compose_status" not in frame.columns or "case_id" not in frame.columns:
        return ""
    status = frame["compose_status"].astype(str)
    return _join_unique(frame.loc[status.isin(statuses), "case_id"])


def _build_total_provenance(composed: pd.DataFrame, merge_keys: list[str]) -> pd.DataFrame:
    if composed is None or composed.empty:
        return pd.DataFrame(columns=merge_keys)

    records: list[dict] = []
    group_key = merge_keys[0] if len(merge_keys) == 1 else merge_keys
    for key_values, group in composed.groupby(group_key, dropna=False, sort=True):
        if len(merge_keys) == 1:
            key_values = (key_values,)
        record = {key: value for key, value in zip(merge_keys, key_values)}
        if "compose_status" in group.columns:
            status = group["compose_status"].astype(str)
        else:
            status = pd.Series("", index=group.index, dtype=str)
        record.update(
            original_case_ids=_join_unique(group.get("case_id", pd.Series(dtype=str))),
            measured_case_ids=_status_case_ids(group, {"pass"}),
            estimated_case_ids=_status_case_ids(group, {"estimated"}),
            missing_case_ids=_join_unique(group.loc[~status.isin({"pass", "estimated"}), "case_id"]) if "case_id" in group.columns else "",
            original_apps=_join_unique(group.get("app", pd.Series(dtype=str))),
            original_args=_join_unique(group.get("args", pd.Series(dtype=str))),
            original_kinds=_join_unique(group.get("kind", pd.Series(dtype=str))),
            original_ops=_join_unique(group.get("op", pd.Series(dtype=str))),
            original_backends=_join_unique(group.get("backend", pd.Series(dtype=str))),
            original_names=_join_unique(group.get("name", pd.Series(dtype=str))),
            original_compose_statuses=_join_unique(status),
            original_source_raw_dbs=_join_unique(group.get("source_raw_dbs", pd.Series(dtype=str))),
            original_source_run_ids=_join_unique(group.get("source_run_ids", pd.Series(dtype=str))),
            original_selected_run_ids=_join_unique(group.get("selected_run_id", pd.Series(dtype=str))),
            original_selected_timestamp_utc=_join_unique(group.get("selected_timestamp_utc", pd.Series(dtype=str))),
            original_source_fpga_bin_labels=_join_unique(group.get("source_fpga_bin_labels", pd.Series(dtype=str))),
            original_source_xclbin_sha256s=_join_unique(group.get("source_xclbin_sha256s", pd.Series(dtype=str))),
            original_source_suites=_join_unique(group.get("source_suites", pd.Series(dtype=str))),
            original_estimate_source_case_ids=_join_unique(group.get("estimate_source_case_id", pd.Series(dtype=str))),
            original_estimate_source_raw_dbs=_join_unique(group.get("estimate_source_raw_dbs", pd.Series(dtype=str))),
        )
        records.append(record)
    return pd.DataFrame(records)


def _count_value(value) -> int:
    number = pd.to_numeric(value, errors="coerce")
    if pd.isna(number):
        return 0
    return int(number)


def _numeric_total_column(frame: pd.DataFrame, column: str, default=0) -> pd.Series:
    if column in frame.columns:
        return pd.to_numeric(frame[column], errors="coerce")
    return pd.Series(default, index=frame.index)


def _final_result_source(row: pd.Series) -> str:
    pass_count = _count_value(row.get("pass_case_count", 0))
    estimated_count = _count_value(row.get("estimated_case_count", 0))
    missing_count = _count_value(row.get("missing_case_count", 0))
    if missing_count and not pass_count and not estimated_count:
        return "missing"
    if estimated_count and pass_count:
        return "mixed_measured_estimated"
    if estimated_count:
        return "estimated"
    if pass_count:
        return "measured"
    if missing_count:
        return "mixed_missing"
    return "unknown"


def _build_total_csv_frame(result: PlotRunResult) -> pd.DataFrame:
    if result.plot_data is None:
        return pd.DataFrame()
    total = result.plot_data.copy()
    total["out_tokens"] = TARGET_GENERATION_OUT_TOKENS
    total["aggregation_kind"] = total["stage"].astype(str).map(
        lambda stage: "average_tpot" if stage == "generation" else "total"
    )
    final_total = pd.to_numeric(total.get("total_latency_us"), errors="coerce")
    total["final_total_metric_value"] = final_total
    total["final_total_latency_us"] = final_total
    total["final_total_latency_s"] = total["final_total_latency_us"] / 1_000_000.0
    total["final_result_source"] = total.apply(_final_result_source, axis=1)

    if "estimate_mode" in total.columns:
        modes = total["estimate_mode"].fillna("").astype(str)
    else:
        modes = pd.Series("", index=total.index)
    total["estimate_applied"] = _numeric_total_column(total, "estimated_case_count", 0).fillna(0).astype(int) > 0
    total["interpolation_applied"] = modes.str.contains("interpolation", regex=False)
    total["extrapolation_applied"] = modes.str.contains("extrapolation", regex=False)

    if result.composed is not None and not result.composed.empty:
        merge_keys = [
            key for key in ("metric", "stage", "seq_len", "batch", "variant")
            if key in total.columns and key in result.composed.columns
        ]
        if merge_keys:
            provenance = _build_total_provenance(result.composed, merge_keys)
            left = total.copy()
            right = provenance.copy()
            temp_keys = []
            for key in merge_keys:
                temp_key = f"__merge_{key}"
                temp_keys.append(temp_key)
                left[temp_key] = left[key].astype(str)
                right[temp_key] = right[key].astype(str)
            right = right.drop(columns=merge_keys)
            total = left.merge(right, on=temp_keys, how="left").drop(columns=temp_keys)

    preferred = [
        "metric", "stage", "batch", "seq_len", "out_tokens", "aggregation_kind", "variant",
        "final_total_metric_value", "final_total_latency_us", "final_total_latency_s", "final_result_source",
        "estimate_applied", "interpolation_applied", "extrapolation_applied",
        "case_count", "pass_case_count", "estimated_case_count", "missing_case_count",
        "original_case_ids", "measured_case_ids", "estimated_case_ids", "missing_case_ids",
        "original_apps", "original_args", "original_kinds", "original_ops", "original_backends", "original_names",
        "original_compose_statuses", "original_source_suites", "original_source_raw_dbs",
        "original_source_run_ids", "original_selected_run_ids", "original_selected_timestamp_utc",
        "original_source_fpga_bin_labels", "original_source_xclbin_sha256s",
        "estimate_model", "estimate_basis", "estimate_selected_by", "estimate_mode", "estimate_group",
        "estimate_source_case_id", "estimate_source_raw_dbs",
        "original_estimate_source_case_ids", "original_estimate_source_raw_dbs",
    ]
    ordered = [column for column in preferred if column in total.columns]
    ordered.extend(column for column in total.columns if column not in ordered)
    return total[ordered]


def _write_total_csv(result: PlotRunResult) -> Path | None:
    if result.plot_data is None or result.composed is None:
        return None
    total = _build_total_csv_frame(result)
    if total.empty:
        return None
    result.out_dir.mkdir(parents=True, exist_ok=True)
    path = result.out_dir / TOTAL_CSV_NAME
    total.to_csv(path, index=False)
    result.total_csv_path = path
    return path


def _require_composed_input() -> pd.DataFrame:
    if COMPOSED_INPUT is None:
        raise RuntimeError("prepare composed input has not been loaded")
    return COMPOSED_INPUT


def _composed_for_model(model: str) -> pd.DataFrame:
    composed = _require_composed_input()
    selected = composed[composed["model"].astype(str).eq(model)].copy()
    if selected.empty:
        available = sorted(composed["model"].dropna().astype(str).unique())
        raise ValueError(
            f"composed CSV has no rows for model {model!r}; available models: {available}"
        )
    return selected


def _source_suite_map(composed: pd.DataFrame) -> dict[str, str]:
    source_column = "suite_file" if "suite_file" in composed.columns else "suite"
    return dict(
        zip(
            composed["case_id"].astype(str),
            composed[source_column].fillna("").astype(str),
        )
    )


def _normalize_generation_latency(data):
    for frame in (data.plot_data, data.stack_data):
        generation = frame["stage"].astype(str).eq("generation")
        frame.loc[generation, "total_latency_us"] = (
            pd.to_numeric(
                frame.loc[generation, "total_latency_us"], errors="coerce"
            )
            / TARGET_GENERATION_OUT_TOKENS
        )
    return data


def _prepare_versions_from_composed(
    composed: pd.DataFrame,
    options: SuiteBarPlotOptions,
):
    source_suites = _source_suite_map(composed)

    def _prepared_rows(current_options: SuiteBarPlotOptions) -> pd.DataFrame:
        models = tuple(sorted(composed["model"].dropna().astype(str).unique()))
        rule_key = tuple(
            (rule.name, repr(rule.condition), float(rule.scale))
            for rule in current_options.case_latency_scale_rules
        )
        key = (
            id(COMPOSED_INPUT) if COMPOSED_INPUT is not None else id(composed),
            models,
            rule_key,
            tuple(id(row_filter) for row_filter in current_options.row_filters),
        )
        cached = _PREPARED_ROW_CACHE.get(key)
        if cached is None:
            cached = latency_plot_module._prepare_suite_bar_rows_from_composed(
                composed,
                source_suites,
                current_options,
            )
            _PREPARED_ROW_CACHE[key] = cached
        return cached

    base_options = replace(
        options,
        latency_scale_rules=(),
        case_latency_scale_rules=(),
        latency_estimate=None,
    )
    base = latency_plot_module.SuiteBarData(
        *latency_plot_module._aggregate_suite_bar_rows(
            _prepared_rows(base_options),
            base_options,
        )
    )
    base = _normalize_generation_latency(base)

    scaled = None
    if options.case_latency_scale_rules:
        scaled_options = replace(options, latency_scale_rules=(), latency_estimate=None)
        scaled = latency_plot_module.SuiteBarData(
            *latency_plot_module._aggregate_suite_bar_rows(
                _prepared_rows(scaled_options),
                scaled_options,
            )
        )
        scaled = _normalize_generation_latency(scaled)

    return latency_plot_module.SuiteBarDataVersions(base=base, scaled=scaled)


def _make_suite_options(
    out_dir: Path,
    *,
    model: str,
    suite_tag: str,
    stacked: bool,
    stack_by: str = STACK_BY,
    include_c4_alone: bool,
    row_filters: tuple | None,
    shape_selection: ShapeSelection | None,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> tuple[list, SuiteBarPlotOptions]:
    plot_row_filters = _apply_global_row_filters(row_filters)
    if not include_c4_alone and exclude_c4_alone not in plot_row_filters:
        plot_row_filters = (*plot_row_filters, exclude_c4_alone)
    options = SuiteBarPlotOptions(
        raw_dbs=(),
        out_dir=out_dir,
        metric=METRIC,
        select=SELECT,
        missing=MISSING,
        x=X_AXIS,
        hue=HUE_AXIS,
        row=ROW_AXIS,
        col=COL_AXIS,
        stacked=stacked,
        stack_by=stack_by,
        relative=RELATIVE,
        relative_scope=RELATIVE_SCOPE,
        label_maps=plot_label_maps(include_c4_alone=include_c4_alone),
        value_orders=VALUE_ORDERS,
        latency_scale_rules=(),
        case_latency_scale_rules=tuple(
            CASE_LATENCY_SCALE_RULES
            if case_latency_scale_rules is None
            else case_latency_scale_rules
        ),
        latency_estimate=None,
        row_filters=plot_row_filters,
    )
    return [], options


def export_suite_figure_data(
    *,
    model: str,
    suite_tag: str,
    out_name: str,
    stacked: bool,
    stack_by: str = STACK_BY,
    include_c4_alone: bool = INCLUDE_C4_ALONE,
    row_filters: tuple | None = None,
    shape_selection: ShapeSelection | None = E2E_SHAPE_SELECTION,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> PlotRunResult:
    out_dir = FIGURE_OUTPUT_ROOT / out_name
    _, options = _make_suite_options(
        out_dir,
        model=model,
        suite_tag=suite_tag,
        stacked=stacked,
        stack_by=stack_by,
        include_c4_alone=include_c4_alone,
        row_filters=row_filters,
        shape_selection=shape_selection,
        case_latency_scale_rules=case_latency_scale_rules,
    )
    composed = _composed_for_model(model)
    versions = _prepare_versions_from_composed(composed, options)
    plot_input = versions.final
    result = PlotRunResult(
        tag=suite_tag,
        out_dir=out_dir,
        suites=[],
        options=options,
        versions=versions,
        composed=plot_input.composed,
        plot_data=plot_input.plot_data,
        stack_data=plot_input.stack_data,
        figure_data=pd.DataFrame(),
        cache_status="rebuilt",
    )
    csv_path = _write_latency_figure_data(result)
    result.figure_data = _read_figure_data(csv_path)
    _write_total_csv(result)
    return result


def load_or_export_suite_figure_data(
    *,
    model: str,
    suite_tag: str,
    out_name: str,
    stacked: bool,
    stack_by: str = STACK_BY,
    include_c4_alone: bool = INCLUDE_C4_ALONE,
    row_filters: tuple | None = None,
    shape_selection: ShapeSelection | None = E2E_SHAPE_SELECTION,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
    force_rebuild: bool | None = None,
) -> PlotRunResult:
    csv_path = figure_data_path(out_name)
    total_path = total_data_path(out_name)
    force = FORCE_REBUILD_FIGURE_DATA if force_rebuild is None else force_rebuild
    if USE_FIGURE_DATA_CACHE and csv_path.exists() and total_path.exists() and not force:
        return PlotRunResult(
            tag=suite_tag,
            out_dir=csv_path.parent,
            suites=[],
            options=None,
            versions=None,
            composed=None,
            plot_data=None,
            stack_data=None,
            figure_data=_read_figure_data(csv_path),
            total_csv_path=total_path,
            cache_status="cache",
        )
    if USE_FIGURE_DATA_CACHE and csv_path.exists() and not total_path.exists() and not force:
        print(f"cache for {out_name!r} is missing {TOTAL_CSV_NAME}; rebuilding plot data")
    return export_suite_figure_data(
        model=model,
        suite_tag=suite_tag,
        out_name=out_name,
        stacked=stacked,
        stack_by=stack_by,
        include_c4_alone=include_c4_alone,
        row_filters=row_filters,
        shape_selection=shape_selection,
        case_latency_scale_rules=case_latency_scale_rules,
    )


def export_no_area_norm_figure_data(
    source: PlotRunResult,
    *,
    out_name: str,
) -> PlotRunResult:
    """Write the unscaled version already produced by the normalized run."""
    if source.versions is None or source.options is None:
        raise ValueError("source result has no in-memory data versions")

    plot_input = source.versions.base
    out_dir = FIGURE_OUTPUT_ROOT / out_name
    options = replace(
        source.options,
        out_dir=out_dir,
        latency_scale_rules=(),
        case_latency_scale_rules=(),
    )
    result = PlotRunResult(
        tag=source.tag,
        out_dir=out_dir,
        suites=source.suites,
        options=options,
        versions=None,
        composed=plot_input.composed,
        plot_data=plot_input.plot_data,
        stack_data=plot_input.stack_data,
        figure_data=pd.DataFrame(),
        cache_status="derived",
    )
    csv_path = _write_latency_figure_data(result)
    result.figure_data = _read_figure_data(csv_path)
    _write_total_csv(result)
    return result


def load_or_export_no_area_norm_figure_data(
    source: PlotRunResult,
    *,
    model: str,
    suite_tag: str,
    out_name: str,
    stacked: bool,
    stack_by: str = STACK_BY,
    row_filters: tuple | None = None,
    shape_selection: ShapeSelection | None = E2E_SHAPE_SELECTION,
) -> PlotRunResult:
    if getattr(source, "versions", None) is not None and not LATENCY_SCALE_RULES:
        return export_no_area_norm_figure_data(source, out_name=out_name)
    rebuild_kwargs = {
        "model": model,
        "suite_tag": suite_tag,
        "out_name": out_name,
        "stacked": stacked,
        "stack_by": stack_by,
        "include_c4_alone": INCLUDE_C4_ALONE,
        "case_latency_scale_rules": (),
    }
    if row_filters is not None:
        rebuild_kwargs["row_filters"] = row_filters
    if row_filters is not None or shape_selection != E2E_SHAPE_SELECTION:
        rebuild_kwargs["shape_selection"] = shape_selection
    return load_or_export_suite_figure_data(
        **rebuild_kwargs,
    )


GEMM_ONLY_FILTERS = (
    GEMM_ONLY_SHAPE_FILTER,
    *LATENCY_DEQUANTIZATION_FILTERS,
    lambda df: df["kind"].eq("gemm"),
    *C4_ALONE_FILTERS,
)
main_all_result: PlotRunResult | None = None

# Energy per token.
ENERGY_IDLE_POWER_W = FPGA_IDLE_POWER
INCLUDE_IDLE_POWER = False
# power_dynamic_avg_W is the measured kernel power above idle.  The board and
# VCC metrics include idle power and therefore are intentionally not exported.
ENERGY_POWER_METRICS = ("power_dynamic_avg_W",)

# Idle-subtracted pure/total dynamic-energy ratios measured by
# tests/regression/dequant_hbm_energy on U55C C4_v3.  The weight rule uses the
# 128x128 qdir=0 measurement.  The KV rule uses the available qdir=1, qblk=32
# measurement; qblk=128 SpinQuant KV kernels should be remeasured when possible.
DEQUANT_PURE_ENERGY_RULES = (
    LatencyScaleRule(
        "weight_dequant_pure_energy",
        {"kind": "dequantization", "name": {"regex": r"_weight_"}},
        0.53230,
    ),
    LatencyScaleRule(
        "kv_dequant_pure_energy",
        {
            "kind": "dequantization",
            "name": {"regex": r"^kv_cache_dequant_"},
        },
        0.25339,
    ),
)
PREPARE_ENERGY = os.environ.get("LATENCY_PREPARE_ENERGY", "1").lower() not in {
    "0",
    "false",
    "no",
}
ENERGY_FPGA_PERIOD_S = DEFAULT_FPGA_PERIOD_S


def _shape_selection_matches(
    left: ShapeSelection,
    right: ShapeSelection,
) -> bool:
    return left == right


def _energy_composed_rows(
    *,
    model: str,
    suite_tag: str,
    main_result: PlotRunResult | None,
    out_name: str,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> pd.DataFrame:
    if (
        main_result is not None
        and main_result.composed is not None
        and _shape_selection_matches(E2E_SHAPE_SELECTION, ENERGY_SHAPE_SELECTION)
        and LATENCY_DEQUANTIZATION_POLICY == ENERGY_DEQUANTIZATION_POLICY
        and case_latency_scale_rules is None
    ):
        return main_result.composed

    rebuilt = export_suite_figure_data(
        model=model,
        suite_tag=suite_tag,
        out_name=out_name,
        stacked=False,
        include_c4_alone=INCLUDE_C4_ALONE,
        row_filters=(ENERGY_SHAPE_FILTER, *ENERGY_DEQUANTIZATION_FILTERS),
        shape_selection=ENERGY_SHAPE_SELECTION,
        case_latency_scale_rules=case_latency_scale_rules,
    )
    return rebuilt.composed


def export_energy_figure_data_pair(
    *,
    model: str,
    suite_tag: str,
    main_result: PlotRunResult | None,
    out_name: str,
    stacked_out_name: str,
    gemm_layout_vector_stacked_out_name: str | None = None,
    power_metric: str,
    fpga_period_s: float = ENERGY_FPGA_PERIOD_S,
    force_rebuild: bool | None = None,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> tuple[str, ...]:
    """Build energy tables from one shared flat/kind/name-backend calculation."""
    force = FORCE_REBUILD_FIGURE_DATA if force_rebuild is None else force_rebuild
    output_names = (
        (out_name, stacked_out_name)
        if gemm_layout_vector_stacked_out_name is None
        else (
            out_name,
            stacked_out_name,
            gemm_layout_vector_stacked_out_name,
        )
    )
    output_paths = tuple(figure_data_path(name) for name in output_names)
    cached = tuple(USE_FIGURE_DATA_CACHE and path.exists() and not force for path in output_paths)
    if all(cached):
        return tuple("cache" for _name in output_names)

    composition_out_name = next(name for name, is_cached in zip(output_names, cached) if not is_cached)
    composed = _energy_composed_rows(
        model=model,
        suite_tag=suite_tag,
        main_result=main_result,
        out_name=composition_out_name,
        case_latency_scale_rules=case_latency_scale_rules,
    )
    records = list(composed.to_dict(orient="records")) if hasattr(composed, "to_dict") else list(composed)
    rows = energy_rows_from_records(
        records,
        (),
        idle_power_w=ENERGY_IDLE_POWER_W,
        include_idle_power=INCLUDE_IDLE_POWER,
        power_metric=power_metric,
        fpga_period_s=fpga_period_s,
        allow_generic_power_estimate=False,
    )
    split_energy_dequantization_kinds(rows)
    totals = summarize_energy_rows(rows)
    label_maps = plot_label_maps(include_c4_alone=INCLUDE_C4_ALONE)

    summary = add_relative_energy_values(totals, relative_scope=RELATIVE_SCOPE)
    result = plot_script.EnergyExcelResult(
        summary=pd.DataFrame(summary),
        figure_path=FIGURE_OUTPUT_ROOT / out_name / "energy_per_token.png",
    )
    energy_path = plot_script.write_energy_figure_data_csv(result, label_maps=label_maps)
    _annotate_prepared_csv(energy_path)

    components = summarize_energy_rows(rows, group_by=(E2E_STACK_BY,))
    summary = add_relative_energy_component_values(
        components,
        totals,
        relative_scope=RELATIVE_SCOPE,
    )
    result = plot_script.EnergyExcelResult(
        summary=pd.DataFrame(summary),
        figure_path=FIGURE_OUTPUT_ROOT / stacked_out_name / "energy_per_token_stacked.png",
    )
    energy_stacked_path = plot_script.write_energy_stacked_figure_data_csv(
        result,
        label_maps=label_maps,
        stack_by=E2E_STACK_BY,
    )
    _annotate_prepared_csv(energy_stacked_path)

    if gemm_layout_vector_stacked_out_name is not None:
        for row in rows:
            row["name_backend"] = latency_plot_module._stack_key(
                pd.Series(row),
                "name_backend",
            )
        components = summarize_energy_rows(rows, group_by=("name_backend",))
        summary = add_relative_energy_component_values(
            components,
            totals,
            relative_scope=RELATIVE_SCOPE,
        )
        result = plot_script.EnergyExcelResult(
            summary=pd.DataFrame(summary),
            figure_path=(
                FIGURE_OUTPUT_ROOT
                / gemm_layout_vector_stacked_out_name
                / "energy_per_token_gemm_layout_vector_stacked.png"
            ),
        )
        name_backend_path = plot_script.write_energy_stacked_figure_data_csv(
            result,
            label_maps=label_maps,
            stack_by="name_backend",
        )
        _annotate_prepared_csv(name_backend_path)

    return tuple("rebuilt" for _name in output_names)


def export_gemm_only_energy_figure_data(
    *,
    model: str,
    suite_tag: str,
    gemm_only_result: PlotRunResult | None,
    out_name: str,
    power_metric: str,
    fpga_period_s: float = ENERGY_FPGA_PERIOD_S,
    force_rebuild: bool | None = None,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> str:
    """Build name-stacked GEMM-only energy-per-token figure data."""
    force = FORCE_REBUILD_FIGURE_DATA if force_rebuild is None else force_rebuild
    output_path = figure_data_path(out_name)
    if USE_FIGURE_DATA_CACHE and output_path.exists() and not force:
        return "cache"

    if gemm_only_result is not None and gemm_only_result.composed is not None:
        composed = gemm_only_result.composed
    else:
        rebuilt = export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=out_name,
            stacked=True,
            stack_by=STACK_BY,
            include_c4_alone=INCLUDE_C4_ALONE,
            row_filters=GEMM_ONLY_FILTERS,
            shape_selection=GEMM_ONLY_SHAPE_SELECTION,
            case_latency_scale_rules=case_latency_scale_rules,
        )
        composed = rebuilt.composed

    records = (
        list(composed.to_dict(orient="records"))
        if hasattr(composed, "to_dict")
        else list(composed)
    )
    rows = energy_rows_from_records(
        records,
        (),
        idle_power_w=ENERGY_IDLE_POWER_W,
        include_idle_power=INCLUDE_IDLE_POWER,
        power_metric=power_metric,
        fpga_period_s=fpga_period_s,
        allow_generic_power_estimate=False,
    )
    totals = summarize_energy_rows(rows)
    components = summarize_energy_rows(rows, group_by=(STACK_BY,))
    summary = add_relative_energy_component_values(
        components,
        totals,
        relative_scope=RELATIVE_SCOPE,
    )
    result = plot_script.EnergyExcelResult(
        summary=pd.DataFrame(summary),
        figure_path=(
            FIGURE_OUTPUT_ROOT
            / out_name
            / "gemm_only_energy_per_token_stacked.png"
        ),
    )
    gemm_energy_path = plot_script.write_energy_stacked_figure_data_csv(
        result,
        label_maps=plot_label_maps(include_c4_alone=INCLUDE_C4_ALONE),
        stack_by=STACK_BY,
    )
    _annotate_prepared_csv(gemm_energy_path)
    return "rebuilt"


def _vectorized_energy_rows(
    composed: pd.DataFrame,
    *,
    power_metrics: tuple[str, ...] = ENERGY_POWER_METRICS,
    fpga_period_s: float = ENERGY_FPGA_PERIOD_S,
) -> pd.DataFrame:
    """Build complete energy component rows for all power metrics together."""
    base = composed.copy()
    numeric = lambda column, default=None: (
        pd.to_numeric(base[column], errors="coerce")
        if column in base.columns
        else pd.Series(default, index=base.index, dtype="float64")
    )
    stage = base["stage"].fillna("").astype(str).str.lower()
    batch = numeric("batch")
    seq_len = numeric("seq_len")
    if "gen_kv_len" in base.columns:
        seq_len = seq_len.where(~stage.eq("generation"), numeric("gen_kv_len"))
    if "prefill_seq_len" in base.columns:
        seq_len = seq_len.where(~stage.eq("prefill"), numeric("prefill_seq_len"))
    out_tokens = numeric("out_tokens", 1.0).fillna(1.0)
    tokens = batch * seq_len
    tokens = tokens.where(~stage.eq("generation"), batch * out_tokens)

    cycle_avg = numeric("fpga_cycle_avg")
    if "fpga_cycle" in base.columns:
        cycle_avg = cycle_avg.fillna(numeric("fpga_cycle"))
    metric = base.get("metric", pd.Series("", index=base.index)).astype(str)
    cycle_avg = cycle_avg.where(~metric.eq("fpga_cycle"), numeric("latency_us"))
    calls = numeric("calls_per_forward", 1.0).fillna(1.0)
    calls = calls.where(calls.ne(0.0), 1.0)
    weighted_cycles = cycle_avg * calls

    period = numeric("fpga_period_s")
    for column in ("fpga_freq_mhz", "power_fpga_freq_mhz", "clock_mhz"):
        if column in base.columns:
            freq = numeric(column)
            period = period.fillna(1.0 / (freq * 1_000_000.0))
    unresolved_period = period.isna()
    if bool(unresolved_period.any()):
        period_keys = pd.DataFrame(index=base.index)
        for column in (
            "expected_fpga_bin_label",
            "fpga_bin_label",
            "source_fpga_bin_labels",
        ):
            period_keys[column] = base.get(
                column,
                pd.Series("", index=base.index),
            ).fillna("").astype(str)
        key_values = period_keys.astype(str).agg("\x1f".join, axis=1)
        for key in key_values[unresolved_period].drop_duplicates():
            indexes = key_values.index[key_values.eq(key)]
            representative = base.loc[indexes[0]].to_dict()
            resolved = resolve_energy_fpga_period_s(
                representative,
                None,
                default=fpga_period_s,
            )
            period.loc[indexes] = resolved
    period = period.fillna(float(fpga_period_s))
    energy_time = weighted_cycles * period

    base["energy_stage"] = stage
    base["energy_batch"] = batch
    base["energy_seq_len"] = seq_len
    base["energy_tokens"] = tokens
    base["fpga_cycle_avg"] = cycle_avg
    base["energy_weighted_fpga_cycles"] = weighted_cycles
    base["fpga_period_s"] = period
    base["energy_time_s"] = energy_time
    base["power_resolution"] = base.get(
        "power_resolution_kind",
        pd.Series("measured", index=base.index),
    ).fillna("measured").astype(str)
    base["power_match_scope"] = "composed"
    base["power_distance"] = numeric("power_interpolation_upper_ratio")
    base["power_source_case_id"] = ""
    base["power_source_fpga_bin_label"] = ""
    base["power_source_app"] = ""
    base["power_source_args"] = ""
    base["power_source_shape_json"] = ""
    base["power_source_samples"] = ""
    base["idle_power_w"] = ENERGY_IDLE_POWER_W
    base["include_idle_power"] = INCLUDE_IDLE_POWER
    base["energy_missing_cycle"] = weighted_cycles.isna()
    base["energy_missing_latency"] = weighted_cycles.isna()

    frames: list[pd.DataFrame] = []
    for power_metric in power_metrics:
        power_column = power_metric.replace("_W", "_w")
        power = numeric(power_column)
        current = base.copy()
        current["power_metric"] = power_metric
        current["raw_power_W"] = power
        current["raw_power_w"] = power
        current["effective_power_W"] = power
        current["effective_power_w"] = power
        current["kernel_energy_j"] = energy_time * power
        current["joules_per_token_component"] = (
            current["kernel_energy_j"] / tokens.where(tokens.gt(0.0))
        )
        current["energy_missing_power"] = power.isna()
        frames.append(current)
    rows = pd.concat(frames, ignore_index=True)
    return _apply_dequant_pure_energy_rules(rows)


def _apply_dequant_pure_energy_rules(rows: pd.DataFrame) -> pd.DataFrame:
    """Replace standalone dequant energy with its measured pure-energy share."""
    adjusted = apply_latency_scale_rules(
        rows,
        DEQUANT_PURE_ENERGY_RULES,
        metric_columns=("kernel_energy_j",),
    )
    applied_rules = adjusted["_latency_scale_rules"].fillna("").astype(str)
    dequantization = adjusted["kind"].astype(str).eq("dequantization")
    unmatched = dequantization & applied_rules.eq("")
    if bool(unmatched.any()):
        names = sorted(
            adjusted.loc[unmatched, "name"].fillna("").astype(str).unique()
        )
        raise ValueError(f"dequant pure-energy rules did not match: {names}")

    tokens = pd.to_numeric(adjusted["energy_tokens"], errors="coerce")
    adjusted["joules_per_token_component"] = (
        pd.to_numeric(adjusted["kernel_energy_j"], errors="coerce")
        / tokens.where(tokens.gt(0.0))
    )
    for rule in DEQUANT_PURE_ENERGY_RULES:
        matched = applied_rules.str.split(";").map(lambda names: rule.name in names)
        print(
            f"energy discount rule {rule.name}: scale={rule.scale:.5f}, "
            f"matched_rows={int(matched.sum())}"
        )
    return adjusted.drop(
        columns=["_latency_scale_factor", "_latency_scale_rules"]
    )


def _energy_summaries_all_metrics(
    composed: pd.DataFrame,
) -> tuple[list[dict], list[dict], list[dict]]:
    rows_frame = _vectorized_energy_rows(composed)
    dequantization = rows_frame["kind"].astype(str).eq("dequantization")
    names = rows_frame["name"].fillna("").astype(str)
    rows_frame.loc[
        dequantization & names.str.contains("_weight_", regex=False),
        "kind",
    ] = "W dequant"
    rows_frame.loc[
        dequantization & names.str.startswith("kv_cache_dequant_"),
        "kind",
    ] = "KV dequant"
    unknown = rows_frame["kind"].astype(str).eq("dequantization")
    if bool(unknown.any()):
        raise ValueError(
            "unclassified dequantization kernel names: "
            f"{sorted(names[unknown].unique())}"
        )
    rows_frame["name_backend"] = latency_plot_module._stack_keys(
        rows_frame,
        "name_backend",
    )
    records = rows_frame.to_dict(orient="records")
    totals = summarize_energy_rows(records)
    kinds = summarize_energy_rows(records, group_by=(E2E_STACK_BY,))
    name_backends = summarize_energy_rows(records, group_by=("name_backend",))
    return totals, kinds, name_backends


def _metric_summary(rows: list[dict], power_metric: str) -> list[dict]:
    return [row for row in rows if str(row.get("power_metric")) == power_metric]


def _relative_totals_all_metrics(rows: list[dict]) -> list[dict]:
    return [
        relative
        for power_metric in ENERGY_POWER_METRICS
        for relative in add_relative_energy_values(
            _metric_summary(rows, power_metric),
            relative_scope=RELATIVE_SCOPE,
        )
    ]


def _relative_components_all_metrics(
    components: list[dict],
    totals: list[dict],
) -> list[dict]:
    return [
        relative
        for power_metric in ENERGY_POWER_METRICS
        for relative in add_relative_energy_component_values(
            _metric_summary(components, power_metric),
            _metric_summary(totals, power_metric),
            relative_scope=RELATIVE_SCOPE,
        )
    ]


def export_energy_figure_data_all_metrics(
    *,
    model: str,
    suite_tag: str,
    main_result: PlotRunResult | None,
    no_area_norm: bool,
) -> tuple[list[str], list[str], list[str]]:
    """Export flat/kind/name-backend energy CSVs with one all-metric pass."""
    rules = () if no_area_norm else None
    suffix_out = energy_no_area_norm_out_name if no_area_norm else energy_out_name
    suffix_stacked = (
        energy_no_area_norm_stacked_out_name
        if no_area_norm
        else energy_stacked_out_name
    )
    suffix_name_backend = (
        energy_no_area_norm_gemm_layout_vector_stacked_out_name
        if no_area_norm
        else energy_gemm_layout_vector_stacked_out_name
    )
    probe_name = suffix_out(model, ENERGY_POWER_METRICS[0])
    composed = _energy_composed_rows(
        model=model,
        suite_tag=suite_tag,
        main_result=main_result,
        out_name=probe_name,
        case_latency_scale_rules=rules,
    )
    raw_totals, kinds, name_backends = _energy_summaries_all_metrics(composed)
    totals = _relative_totals_all_metrics(raw_totals)
    kinds = _relative_components_all_metrics(kinds, raw_totals)
    name_backends = _relative_components_all_metrics(name_backends, raw_totals)
    label_maps = plot_label_maps(include_c4_alone=INCLUDE_C4_ALONE)
    flat_names: list[str] = []
    stacked_names: list[str] = []
    name_backend_names: list[str] = []
    for power_metric in ENERGY_POWER_METRICS:
        flat_name = suffix_out(model, power_metric)
        result = plot_script.EnergyExcelResult(
            summary=pd.DataFrame(_metric_summary(totals, power_metric)),
            figure_path=FIGURE_OUTPUT_ROOT / flat_name / "energy_per_token.png",
        )
        path = plot_script.write_energy_figure_data_csv(result, label_maps=label_maps)
        _annotate_prepared_csv(path)
        flat_names.append(flat_name)

        stacked_name = suffix_stacked(model, power_metric)
        result = plot_script.EnergyExcelResult(
            summary=pd.DataFrame(_metric_summary(kinds, power_metric)),
            figure_path=FIGURE_OUTPUT_ROOT / stacked_name / "energy_per_token_stacked.png",
        )
        path = plot_script.write_energy_stacked_figure_data_csv(
            result,
            label_maps=label_maps,
            stack_by=E2E_STACK_BY,
        )
        _annotate_prepared_csv(path)
        stacked_names.append(stacked_name)

        name_backend_name = suffix_name_backend(model, power_metric)
        result = plot_script.EnergyExcelResult(
            summary=pd.DataFrame(_metric_summary(name_backends, power_metric)),
            figure_path=(
                FIGURE_OUTPUT_ROOT
                / name_backend_name
                / "energy_per_token_gemm_layout_vector_stacked.png"
            ),
        )
        path = plot_script.write_energy_stacked_figure_data_csv(
            result,
            label_maps=label_maps,
            stack_by="name_backend",
        )
        _annotate_prepared_csv(path)
        name_backend_names.append(name_backend_name)
    return flat_names, stacked_names, name_backend_names


def export_gemm_only_energy_all_metrics(
    *,
    model: str,
    gemm_result: PlotRunResult,
    no_area_norm: bool,
) -> list[str]:
    """Export all GEMM-only power metrics from one vectorized energy table."""
    if gemm_result.composed is None:
        raise ValueError("GEMM-only energy source has no composed rows")
    rows_frame = _vectorized_energy_rows(gemm_result.composed)
    records = rows_frame.to_dict(orient="records")
    raw_totals = summarize_energy_rows(records)
    components = summarize_energy_rows(records, group_by=(STACK_BY,))
    summary = _relative_components_all_metrics(components, raw_totals)
    out_name_fn = (
        gemm_only_energy_no_area_norm_out_name
        if no_area_norm
        else gemm_only_energy_out_name
    )
    output_names: list[str] = []
    for power_metric in ENERGY_POWER_METRICS:
        out_name = out_name_fn(model, power_metric)
        result = plot_script.EnergyExcelResult(
            summary=pd.DataFrame(_metric_summary(summary, power_metric)),
            figure_path=(
                FIGURE_OUTPUT_ROOT
                / out_name
                / "gemm_only_energy_per_token_stacked.png"
            ),
        )
        path = plot_script.write_energy_stacked_figure_data_csv(
            result,
            label_maps=plot_label_maps(include_c4_alone=INCLUDE_C4_ALONE),
            stack_by=STACK_BY,
        )
        _annotate_prepared_csv(path)
        output_names.append(out_name)
    return output_names


BUILD_LLAMA_COMPARE = False
LLAMA_COMPARE_OUT_DIR = FIGURE_OUTPUT_ROOT / "llama_compare"
LLAMA_COMPARE_CSV = LLAMA_COMPARE_OUT_DIR / "c1_vs_c4_speedup_batch1.csv"
LLAMA_COMPARE_CACHE_VERSION = "raw_roots_v4_fpga_cycle_latency_forward_calls"
LLAMA_COMPARE_BATCH = 1
LLAMA_COMPARE_SEQ_ORDER = [512, 1024, 2048, 4096, 8192, 16384, 32768]
LLAMA_COMPARE_SEQ_LABELS = {
    512: "512",
    1024: "1k",
    2048: "2k",
    4096: "4k",
    8192: "8k",
    16384: "16k",
    32768: "32k",
}
LLAMA_COMPARE_STAGES = ("prefill", "generation")
ALL_LLAMA_COMPARE_MODELS = (
    {
        "model": "llama2-7b",
        "display_model": "Llama2-7B",
        "suite_prefix": "llama2_7b",
        "raw_db_roots": (RAW_DB_ROOTS["llama2_7b"],),
    },
    {
        "model": "llama3-8b",
        "display_model": "Llama3-8B",
        "suite_prefix": "llama3_8b",
        "raw_db_roots": (RAW_DB_ROOTS["llama3_8b"],),
    },
    {
        "model": "llama3.2-1b",
        "display_model": "Llama3.2-1B",
        "suite_prefix": "llama3p2_1b",
        "raw_db_roots": (RAW_DB_ROOTS["llama3p2_1b"],),
    },
    {
        "model": "llama3.2-3b",
        "display_model": "Llama3.2-3B",
        "suite_prefix": "llama3p2_3b",
        "raw_db_roots": (RAW_DB_ROOTS["llama3p2_3b"],),
    },
)
LLAMA_COMPARE_MODELS = tuple(
    model_spec for model_spec in ALL_LLAMA_COMPARE_MODELS if model_spec["suite_prefix"] in TARGET_MODELS
)
LLAMA_COMPARE_RAW_DB_SUBDIRS = RAW_DB_SUBDIRS
LLAMA_COMPARE_SUITE_SUFFIXES = (
    "prefill_C1",
    "prefill_C2",
    "prefill_C3",
    "prefill_C4_alone",
    "prefill_C4_fused",
    "generation_C1",
    "generation_C2",
    "generation_C3",
    "generation_C4_alone",
    "generation_C4_fused",
)
LLAMA_COMPARE_C1_VARIANT = "all_sgemm_tcu_spinquant"
LLAMA_COMPARE_C4_VARIANT = C4_FUSED_VARIANT
LLAMA_COMPARE_FORCE_REBUILD = True


def _llama_compare_raw_dbs(raw_db_roots: tuple[Path, ...]) -> tuple[Path, ...]:
    return tuple(
        raw_db_root / subdir / "raw_db.csv"
        for raw_db_root in raw_db_roots
        for subdir in LLAMA_COMPARE_RAW_DB_SUBDIRS
    )


def _llama_compare_suite_paths(suite_prefix: str, tag: str | None = None) -> tuple[Path, ...]:
    suite_tag = suite_tag_for_model(suite_prefix) if tag is None else tag
    return tuple(
        LATENCY_DIR / "suites" / suite_tag / f"{suite_prefix}_{suffix}.yaml"
        for suffix in LLAMA_COMPARE_SUITE_SUFFIXES
    )


def _require_existing_paths(paths) -> None:
    missing = [path for path in paths if not path.exists()]
    if missing:
        raise FileNotFoundError("missing llama comparison inputs:\n" + "\n".join(str(path) for path in missing))


def _numeric_int_column(frame: pd.DataFrame, column: str) -> pd.Series:
    return pd.to_numeric(frame[column], errors="coerce").astype("Int64")


def _compose_llama_compare_model(model_spec: dict) -> pd.DataFrame:
    suite_files = _llama_compare_suite_paths(model_spec["suite_prefix"])
    raw_dbs = _llama_compare_raw_dbs(model_spec["raw_db_roots"])
    _require_existing_paths((*suite_files, *raw_dbs))

    suites = [load_suite(path, repo_root=REPO_ROOT) for path in suite_files]
    options = SuiteBarPlotOptions(
        raw_dbs=raw_dbs,
        out_dir=LLAMA_COMPARE_OUT_DIR / f"_compose_{model_spec['suite_prefix']}",
        metric=METRIC,
        select=SELECT,
        missing=MISSING,
        x=X_AXIS,
        hue=HUE_AXIS,
        row=ROW_AXIS,
        col=COL_AXIS,
        stacked=False,
        stack_by=STACK_BY,
        relative=False,
        label_maps=plot_label_maps(include_c4_alone=INCLUDE_C4_ALONE),
        value_orders=VALUE_ORDERS,
        latency_scale_rules=tuple(LATENCY_SCALE_RULES),
        case_latency_scale_rules=tuple(CASE_LATENCY_SCALE_RULES),
        latency_estimate=None,
        row_filters=LATENCY_DEQUANTIZATION_FILTERS,
    )
    versions = prepare_suite_bar_data_versions(suites, options)
    plot_data = versions.final.plot_data.copy()
    plot_data["batch"] = _numeric_int_column(plot_data, "batch")
    plot_data["seq_len"] = _numeric_int_column(plot_data, "seq_len")
    plot_data["total_latency_us"] = pd.to_numeric(
        plot_data["total_latency_us"], errors="coerce"
    )

    variants = {LLAMA_COMPARE_C1_VARIANT, LLAMA_COMPARE_C4_VARIANT}
    filtered = plot_data[
        plot_data["batch"].eq(LLAMA_COMPARE_BATCH)
        & plot_data["seq_len"].isin(LLAMA_COMPARE_SEQ_ORDER)
        & plot_data["stage"].isin(LLAMA_COMPARE_STAGES)
        & plot_data["variant"].isin(variants)
    ].copy()
    count_columns = [
        "case_count",
        "pass_case_count",
        "estimated_case_count",
        "missing_case_count",
    ]
    grouped = (
        filtered.groupby(["stage", "batch", "seq_len", "variant"], dropna=False, as_index=False)
        .agg(
            total_latency_us=("total_latency_us", "sum"),
            **{column: (column, "sum") for column in count_columns if column in filtered.columns},
        )
    )
    indexed = grouped.set_index(["stage", "batch", "seq_len", "variant"])

    records = []
    for stage in LLAMA_COMPARE_STAGES:
        for seq_len in LLAMA_COMPARE_SEQ_ORDER:
            c1_key = (stage, LLAMA_COMPARE_BATCH, seq_len, LLAMA_COMPARE_C1_VARIANT)
            c4_key = (stage, LLAMA_COMPARE_BATCH, seq_len, LLAMA_COMPARE_C4_VARIANT)
            if c1_key not in indexed.index:
                raise ValueError(f"missing C1 row for {model_spec['model']} {stage} seq_len={seq_len}")
            if c4_key not in indexed.index:
                raise ValueError(f"missing C4 row for {model_spec['model']} {stage} seq_len={seq_len}")
            c1 = indexed.loc[c1_key]
            c4 = indexed.loc[c4_key]
            c1_total_latency_us = float(c1["total_latency_us"])
            c4_total_latency_us = float(c4["total_latency_us"])
            if not math.isfinite(c1_total_latency_us) or c1_total_latency_us <= 0.0:
                raise ValueError(f"invalid C1 total latency for {model_spec['model']} {stage} seq_len={seq_len}: {c1_total_latency_us}")
            if not math.isfinite(c4_total_latency_us) or c4_total_latency_us <= 0.0:
                raise ValueError(f"invalid C4 total latency for {model_spec['model']} {stage} seq_len={seq_len}: {c4_total_latency_us}")
            record = {
                "model": model_spec["model"],
                "display_model": model_spec["display_model"],
                "stage": stage,
                "stage_label": LABEL_MAPS["stage"].get(stage, stage),
                "batch": LLAMA_COMPARE_BATCH,
                "seq_len": seq_len,
                "seq_label": LLAMA_COMPARE_SEQ_LABELS[seq_len],
                "seq_rank": LLAMA_COMPARE_SEQ_ORDER.index(seq_len),
                "c1_total_latency_us": c1_total_latency_us,
                "c4_total_latency_us": c4_total_latency_us,
                "c1_over_c4_speedup": c1_total_latency_us / c4_total_latency_us,
                "cache_version": LLAMA_COMPARE_CACHE_VERSION,
            }
            for column in count_columns:
                record[f"c1_{column}"] = int(c1[column]) if column in c1 else 0
                record[f"c4_{column}"] = int(c4[column]) if column in c4 else 0
            records.append(record)
    return pd.DataFrame.from_records(records)


def build_llama_compare_speedup() -> pd.DataFrame:
    if not LLAMA_COMPARE_MODELS:
        raise ValueError(f"no llama comparison model configured for TARGET_MODEL={TARGET_MODEL!r}")
    frames = [_compose_llama_compare_model(model_spec) for model_spec in LLAMA_COMPARE_MODELS]
    out = pd.concat(frames, ignore_index=True)
    out = out.sort_values(["stage", "model", "seq_rank"]).reset_index(drop=True)
    expected_rows = len(LLAMA_COMPARE_MODELS) * len(LLAMA_COMPARE_STAGES) * len(LLAMA_COMPARE_SEQ_ORDER)
    if len(out) != expected_rows:
        raise ValueError(f"expected {expected_rows} comparison rows, got {len(out)}")
    if out["c1_over_c4_speedup"].isna().any() or (out["c1_over_c4_speedup"] <= 0).any():
        raise ValueError("speedup values must be finite and positive")
    LLAMA_COMPARE_OUT_DIR.mkdir(parents=True, exist_ok=True)
    out.to_csv(LLAMA_COMPARE_CSV, index=False)
    return out


def _llama_compare_cache_is_current(data: pd.DataFrame) -> bool:
    return "cache_version" in data.columns and data["cache_version"].eq(LLAMA_COMPARE_CACHE_VERSION).all()


def load_or_build_llama_compare_speedup() -> pd.DataFrame:
    if LLAMA_COMPARE_CSV.exists() and not LLAMA_COMPARE_FORCE_REBUILD:
        cached = pd.read_csv(LLAMA_COMPARE_CSV)
        if _llama_compare_cache_is_current(cached):
            print(f"comparison data source: cached {LLAMA_COMPARE_CSV}")
            return cached
        print(f"comparison data source: stale cache {LLAMA_COMPARE_CSV}; rebuilding")
    else:
        print("comparison data source: rebuilt from suites and raw DBs")
    return build_llama_compare_speedup()


def _configure_out_tokens(out_tokens: int) -> None:
    global TARGET_GENERATION_OUT_TOKENS
    global E2E_GENERATION_OUT_TOKENS, GEMM_ONLY_GENERATION_OUT_TOKENS
    global ENERGY_GENERATION_OUT_TOKENS
    global E2E_SHAPE_SELECTION, GEMM_ONLY_SHAPE_SELECTION, ENERGY_SHAPE_SELECTION
    global E2E_SHAPE_FILTER, GEMM_ONLY_SHAPE_FILTER, ENERGY_SHAPE_FILTER
    global PLOT_ROW_FILTERS, GEMM_ONLY_FILTERS

    TARGET_GENERATION_OUT_TOKENS = out_tokens
    E2E_GENERATION_OUT_TOKENS = out_tokens
    GEMM_ONLY_GENERATION_OUT_TOKENS = out_tokens
    ENERGY_GENERATION_OUT_TOKENS = out_tokens
    E2E_SHAPE_SELECTION = _selection_tuple(
        prefill_batches=E2E_PREFILL_BATCHES,
        prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
        generation_batches=E2E_GENERATION_BATCHES,
        generation_seq_lens=E2E_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    GEMM_ONLY_SHAPE_SELECTION = _selection_tuple(
        prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
        prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
        generation_batches=GEMM_ONLY_GENERATION_BATCHES,
        generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    ENERGY_SHAPE_SELECTION = _selection_tuple(
        prefill_batches=ENERGY_PREFILL_BATCHES,
        prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
        generation_batches=ENERGY_GENERATION_BATCHES,
        generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    E2E_SHAPE_FILTER = _target_shape_filter(
        prefill_batches=E2E_PREFILL_BATCHES,
        prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
        generation_batches=E2E_GENERATION_BATCHES,
        generation_seq_lens=E2E_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    GEMM_ONLY_SHAPE_FILTER = _target_shape_filter(
        prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
        prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
        generation_batches=GEMM_ONLY_GENERATION_BATCHES,
        generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    ENERGY_SHAPE_FILTER = _target_shape_filter(
        prefill_batches=ENERGY_PREFILL_BATCHES,
        prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
        generation_batches=ENERGY_GENERATION_BATCHES,
        generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
        generation_out_tokens=out_tokens,
    )
    PLOT_ROW_FILTERS = (E2E_SHAPE_FILTER, *LATENCY_DEQUANTIZATION_FILTERS)
    GEMM_ONLY_FILTERS = (
        GEMM_ONLY_SHAPE_FILTER,
        *LATENCY_DEQUANTIZATION_FILTERS,
        lambda df: df["kind"].eq("gemm"),
        *C4_ALONE_FILTERS,
    )


def _validate_prepare_composed(frame: pd.DataFrame, out_tokens: int) -> None:
    required = {
        "model", "case_id", "stage", "variant", "kind", "name", "backend",
        "batch", "prefill_seq_len", "gen_kv_len", "out_tokens",
        "output_token_index", "calls_per_forward", "fpga_cycle",
        "fpga_cycle_latency", "fpga_period_s", "latency_us",
        "compose_status", "power_avg_w", "power_vcc_avg_w",
        "power_dynamic_avg_w",
    }
    missing = sorted(required - set(frame.columns))
    if missing:
        raise ValueError(f"composed CSV is missing required columns: {', '.join(missing)}")
    metrics = set(frame["metric"].dropna().astype(str))
    if metrics != {METRIC}:
        raise ValueError(
            f"composed CSV metric must be {METRIC!r}, got {sorted(metrics)}"
        )
    duplicated = frame.duplicated(["model", "case_id"], keep=False)
    if bool(duplicated.any()):
        ids = frame.loc[duplicated, "case_id"].astype(str).drop_duplicates().tolist()
        raise ValueError(f"composed CSV has duplicate logical cases: {ids[:10]}")
    status = frame["compose_status"].astype(str)
    incomplete = ~status.isin({"pass", "estimated"})
    for column in (
        "fpga_cycle", "fpga_cycle_latency", "fpga_period_s", "latency_us",
        "power_avg_w", "power_vcc_avg_w", "power_dynamic_avg_w",
    ):
        incomplete |= pd.to_numeric(frame[column], errors="coerce").isna()
    if bool(incomplete.any()):
        ids = frame.loc[incomplete, "case_id"].astype(str).tolist()
        raise ValueError(f"composed CSV is incomplete: {ids[:10]} ({len(ids)} total)")

    generation = frame[frame["stage"].astype(str).eq("generation")].copy()
    available = sorted(
        pd.to_numeric(generation["out_tokens"], errors="coerce")
        .dropna().astype(int).unique().tolist()
    )
    if out_tokens not in available:
        raise ValueError(
            f"composed CSV has no generation workload for out_tokens={out_tokens}; "
            f"available values: {available}"
        )
    selected = generation[
        pd.to_numeric(generation["out_tokens"], errors="coerce").eq(out_tokens)
    ].copy()
    selected["output_token_index"] = pd.to_numeric(
        selected["output_token_index"], errors="coerce"
    )
    expected = set(range(1, out_tokens + 1))
    group_columns = [
        "model", "variant", "batch", "gen_kv_len", "name", "backend", "op"
    ]
    if "op" not in selected.columns:
        group_columns.remove("op")
    incomplete_groups = []
    for keys, group in selected.groupby(group_columns, dropna=False, sort=False):
        actual = set(group["output_token_index"].dropna().astype(int))
        if actual != expected:
            incomplete_groups.append((keys, sorted(expected - actual)))
    if incomplete_groups:
        raise ValueError(
            "generation composed rows do not cover every output token: "
            f"{incomplete_groups[:5]} ({len(incomplete_groups)} groups)"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prepare plot CSVs from a complete combined composed.csv."
    )
    parser.add_argument("--composed-csv", required=True, type=Path)
    parser.add_argument("--out-tokens", required=True, type=int)
    parser.add_argument(
        "--models",
        default=",".join(TARGET_MODELS),
        help="comma-separated models to prepare (default: configured target models)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=0,
        help="parallel model processes; 0 selects min(model count, 4)",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=None,
        help="Prepared figure-data root; defaults to output_figure/figures_prepare.",
    )
    return parser


def _model_composed_path(combined_path: Path, model: str) -> Path:
    candidate = combined_path.parent.parent / model / combined_path.name
    return candidate if candidate.is_file() else combined_path


def _run_model_prepare_process(
    *,
    model: str,
    composed_csv: Path,
    out_tokens: int,
    output_root: Path | None,
) -> None:
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--composed-csv",
        str(_model_composed_path(composed_csv, model)),
        "--out-tokens",
        str(out_tokens),
        "--models",
        model,
        "--workers",
        "1",
    ]
    if output_root is not None:
        command.extend(("--output-root", str(output_root)))
    subprocess.run(command, check=True)


def main(argv: list[str] | None = None) -> int:
    global main_all_result, COMPOSED_INPUT, FIGURE_OUTPUT_ROOT
    args = build_parser().parse_args(argv)
    if args.out_tokens < 1:
        raise ValueError(f"--out-tokens must be >= 1, got {args.out_tokens}")
    if not args.composed_csv.is_file():
        raise FileNotFoundError(args.composed_csv)
    selected_models = tuple(
        model.strip() for model in str(args.models).split(",") if model.strip()
    )
    unknown_models = sorted(set(selected_models) - set(TARGET_MODELS))
    if not selected_models or unknown_models:
        raise ValueError(
            f"invalid --models selection {selected_models}; "
            f"configured models: {TARGET_MODELS}"
        )
    workers = min(len(selected_models), 4) if args.workers == 0 else args.workers
    if workers < 1:
        raise ValueError(f"--workers must be >= 0, got {args.workers}")
    if len(selected_models) > 1 and workers > 1:
        with ThreadPoolExecutor(max_workers=min(workers, len(selected_models))) as pool:
            futures = [
                pool.submit(
                    _run_model_prepare_process,
                    model=model,
                    composed_csv=args.composed_csv.resolve(),
                    out_tokens=args.out_tokens,
                    output_root=(
                        args.output_root.resolve()
                        if args.output_root is not None
                        else None
                    ),
                )
                for model in selected_models
            ]
            for future in futures:
                future.result()
        return 0
    if args.output_root is not None:
        FIGURE_OUTPUT_ROOT = args.output_root
    _configure_out_tokens(args.out_tokens)
    COMPOSED_INPUT = pd.read_csv(args.composed_csv)
    _validate_prepare_composed(COMPOSED_INPUT, args.out_tokens)

    print(f"target model: {TARGET_MODEL}")
    print(f"target models: {selected_models}")
    print(f"composed source: {args.composed_csv}")
    print(f"prefill batches: {E2E_PREFILL_BATCHES}, prefill seq_lens: {E2E_PREFILL_SEQ_LENS}")
    print(
        f"generation batches: {E2E_GENERATION_BATCHES}, "
        f"generation seq_lens: {E2E_GENERATION_SEQ_LENS}, "
        f"generation out_tokens: {E2E_GENERATION_OUT_TOKENS}"
    )

    prepared_outputs = []
    for model in selected_models:
        suite_tag = suite_tag_for_model(model)
        main_name = main_out_name(model)
        no_area_norm_name = e2e_no_area_norm_out_name(model)
        e2e_stacked_name = e2e_stacked_out_name(model)
        e2e_gemm_layout_stacked_name = e2e_gemm_layout_stacked_out_name(model)
        no_area_norm_stacked_name = e2e_no_area_norm_stacked_out_name(model)
        gemm_name = gemm_only_out_name(model)
        gemm_no_area_norm_name = gemm_only_no_area_norm_out_name(model)

        print(f"model: {model}")
        print(f"suite tag: {suite_tag}")

        main_all_result = load_or_export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=main_name,
            stacked=False,
            include_c4_alone=INCLUDE_C4_ALONE,
        )
        print(f"{model} E2E figure data source: {main_all_result.cache_status}")

        no_area_norm_result = load_or_export_no_area_norm_figure_data(
            main_all_result,
            model=model,
            suite_tag=suite_tag,
            out_name=no_area_norm_name,
            stacked=False,
        )
        print(
            f"{model} E2E figure data without area normalization source: "
            f"{no_area_norm_result.cache_status}"
        )

        e2e_stacked_result = load_or_export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=e2e_stacked_name,
            stacked=True,
            stack_by=E2E_STACK_BY,
            include_c4_alone=INCLUDE_C4_ALONE,
        )
        print(f"{model} E2E stacked figure data source: {e2e_stacked_result.cache_status}")

        e2e_gemm_layout_stacked_result = load_or_export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=e2e_gemm_layout_stacked_name,
            stacked=True,
            stack_by="name_backend",
            include_c4_alone=INCLUDE_C4_ALONE,
        )
        print(
            f"{model} E2E GEMM + layout stacked figure data source: "
            f"{e2e_gemm_layout_stacked_result.cache_status}"
        )

        no_area_norm_stacked_result = load_or_export_no_area_norm_figure_data(
            e2e_stacked_result,
            model=model,
            suite_tag=suite_tag,
            out_name=no_area_norm_stacked_name,
            stacked=True,
            stack_by=E2E_STACK_BY,
        )
        print(
            f"{model} E2E stacked figure data without area normalization source: "
            f"{no_area_norm_stacked_result.cache_status}"
        )

        main_all_gemm_only_result = load_or_export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=gemm_name,
            row_filters=GEMM_ONLY_FILTERS,
            shape_selection=GEMM_ONLY_SHAPE_SELECTION,
            stacked=True,
            include_c4_alone=INCLUDE_C4_ALONE,
        )
        print(f"{model} GEMM-only figure data source: {main_all_gemm_only_result.cache_status}")

        gemm_no_area_norm_result = load_or_export_no_area_norm_figure_data(
            main_all_gemm_only_result,
            model=model,
            suite_tag=suite_tag,
            out_name=gemm_no_area_norm_name,
            stacked=True,
            stack_by=STACK_BY,
            row_filters=GEMM_ONLY_FILTERS,
            shape_selection=GEMM_ONLY_SHAPE_SELECTION,
        )
        print(
            f"{model} GEMM-only figure data without area normalization source: "
            f"{gemm_no_area_norm_result.cache_status}"
        )

        energy_names: list[str] = []
        energy_stacked_names: list[str] = []
        energy_gemm_layout_vector_stacked_names: list[str] = []
        gemm_only_energy_names: list[str] = []
        energy_no_area_norm_names: list[str] = []
        energy_no_area_norm_stacked_names: list[str] = []
        energy_no_area_norm_gemm_layout_vector_stacked_names: list[str] = []
        gemm_only_energy_no_area_norm_names: list[str] = []
        if PREPARE_ENERGY and ENERGY_POWER_METRICS:
            (
                energy_names,
                energy_stacked_names,
                energy_gemm_layout_vector_stacked_names,
            ) = export_energy_figure_data_all_metrics(
                model=model,
                suite_tag=suite_tag,
                main_result=main_all_result,
                no_area_norm=False,
            )
            gemm_only_energy_names = export_gemm_only_energy_all_metrics(
                model=model,
                gemm_result=main_all_gemm_only_result,
                no_area_norm=False,
            )
            (
                energy_no_area_norm_names,
                energy_no_area_norm_stacked_names,
                energy_no_area_norm_gemm_layout_vector_stacked_names,
            ) = export_energy_figure_data_all_metrics(
                model=model,
                suite_tag=suite_tag,
                main_result=None,
                no_area_norm=True,
            )
            gemm_only_energy_no_area_norm_names = (
                export_gemm_only_energy_all_metrics(
                    model=model,
                    gemm_result=gemm_no_area_norm_result,
                    no_area_norm=True,
                )
            )

        prepared_outputs.extend(
            [
                figure_data_path(main_name),
                total_data_path(main_name),
                figure_data_path(no_area_norm_name),
                total_data_path(no_area_norm_name),
                figure_data_path(e2e_stacked_name),
                total_data_path(e2e_stacked_name),
                figure_data_path(e2e_gemm_layout_stacked_name),
                total_data_path(e2e_gemm_layout_stacked_name),
                figure_data_path(no_area_norm_stacked_name),
                total_data_path(no_area_norm_stacked_name),
                figure_data_path(gemm_name),
                total_data_path(gemm_name),
                figure_data_path(gemm_no_area_norm_name),
                total_data_path(gemm_no_area_norm_name),
                *(figure_data_path(energy_name) for energy_name in energy_names),
                *(figure_data_path(energy_name) for energy_name in energy_stacked_names),
                *(
                    figure_data_path(energy_name)
                    for energy_name in energy_gemm_layout_vector_stacked_names
                ),
                *(
                    figure_data_path(energy_name)
                    for energy_name in gemm_only_energy_names
                ),
                *(
                    figure_data_path(energy_name)
                    for energy_name in energy_no_area_norm_names
                ),
                *(
                    figure_data_path(energy_name)
                    for energy_name in energy_no_area_norm_stacked_names
                ),
                *(
                    figure_data_path(energy_name)
                    for energy_name in energy_no_area_norm_gemm_layout_vector_stacked_names
                ),
                *(
                    figure_data_path(energy_name)
                    for energy_name in gemm_only_energy_no_area_norm_names
                ),
            ]
        )

    if BUILD_LLAMA_COMPARE:
        llama_compare_speedup = load_or_build_llama_compare_speedup()
        print(f"wrote {LLAMA_COMPARE_CSV}")
        print(f"rows: {len(llama_compare_speedup)}")
        print(llama_compare_speedup.to_string(index=False))

    if BUILD_LLAMA_COMPARE:
        prepared_outputs.append(LLAMA_COMPARE_CSV)
    for path in prepared_outputs:
        if not path.exists():
            raise FileNotFoundError(path)
        print(f"prepared {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
