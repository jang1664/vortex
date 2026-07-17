#!/usr/bin/env python3
from dataclasses import dataclass, replace
from pathlib import Path
from types import SimpleNamespace
import math
import sys
import warnings

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
from tools.latency_bench.compose import LatencyScaleRule
from tools.latency_bench.estimate import LatencyEstimateOptions
from tools.latency_bench.plot import SuiteBarPlotOptions, prepare_suite_bar_data_versions
from tools.latency_bench.suite import SuiteMatrixOverrides, load_suite
from energy_per_token import (
    DEFAULT_FPGA_PERIOD_S,
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
# TARGET_PREFILL_SEQ_LENS = (1024,2048,4096,8192,16384,32768,65536)
TARGET_PREFILL_SEQ_LENS = (1024,2048,4096,8192,16384,32768)
TARGET_GENERATION_BATCHES = (1, 2, 4)
# TARGET_GENERATION_SEQ_LENS = (1024,2048,4096,8192,16384,32768,65536)
TARGET_GENERATION_SEQ_LENS = (1024,2048,4096,8192,16384,32768)

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
) -> str:
    def _shape_name(batches: tuple[int, ...], seq_lens: tuple[int, ...]) -> str:
        batch_text = "all" if not batches else "-".join(str(value) for value in batches)
        seq_text = "all" if not seq_lens else "-".join(str(value) for value in seq_lens)
        return f"b{batch_text}_s{seq_text}"

    prefill = _shape_name(prefill_batches, prefill_seq_lens)
    generation = _shape_name(generation_batches, generation_seq_lens)
    return f"prefill_{prefill}__generation_{generation}"


ShapeSelection = tuple[tuple[int, ...], tuple[int, ...], tuple[int, ...], tuple[int, ...]]


def _selection_tuple(
    *,
    prefill_batches: tuple[int, ...],
    prefill_seq_lens: tuple[int, ...],
    generation_batches: tuple[int, ...],
    generation_seq_lens: tuple[int, ...],
) -> ShapeSelection:
    return (prefill_batches, prefill_seq_lens, generation_batches, generation_seq_lens)


def _stage_shape_name_for_selection(selection: ShapeSelection) -> str:
    prefill_batches, prefill_seq_lens, generation_batches, generation_seq_lens = selection
    return _stage_shape_name(
        prefill_batches=prefill_batches,
        prefill_seq_lens=prefill_seq_lens,
        generation_batches=generation_batches,
        generation_seq_lens=generation_seq_lens,
    )


E2E_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=E2E_PREFILL_BATCHES,
    prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
    generation_batches=E2E_GENERATION_BATCHES,
    generation_seq_lens=E2E_GENERATION_SEQ_LENS,
)
GEMM_ONLY_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
    prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
    generation_batches=GEMM_ONLY_GENERATION_BATCHES,
    generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
)
ENERGY_SHAPE_SELECTION = _selection_tuple(
    prefill_batches=ENERGY_PREFILL_BATCHES,
    prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
    generation_batches=ENERGY_GENERATION_BATCHES,
    generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
)

def main_out_name(model: str) -> str:
    return f"{model}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_no_area_norm_out_name(model: str) -> str:
    return f"{model}_e2e_no_area_norm_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_stacked_out_name(model: str) -> str:
    return f"{model}_e2e_stacked_by_{E2E_STACK_BY}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def e2e_no_area_norm_stacked_out_name(model: str) -> str:
    return f"{model}_e2e_no_area_norm_stacked_by_{E2E_STACK_BY}_{_stage_shape_name_for_selection(E2E_SHAPE_SELECTION)}"


def gemm_only_out_name(model: str) -> str:
    return f"{model}_gemm_only_{_stage_shape_name_for_selection(GEMM_ONLY_SHAPE_SELECTION)}"


def energy_out_name(model: str, power_metric: str) -> str:
    return f"{model}_energy_per_token_{power_metric}_{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}"


def energy_stacked_out_name(model: str, power_metric: str) -> str:
    return f"{model}_energy_per_token_stacked_by_{E2E_STACK_BY}_{power_metric}_{_stage_shape_name_for_selection(ENERGY_SHAPE_SELECTION)}"

RAW_DB_SUBDIRS = (
    "naive_gemm_simd_th16_tcol32_hwexp_dcache",
    "improve_th16_tcol32_hwexp_dcache",
)
RAW_DB_ROOTS = {
    "llama2_7b": LATENCY_DIR / "outputs_llama2_main",
    "llama3_8b": LATENCY_DIR / "outputs_llama3_main",
}


def raw_dbs_for_model(model: str) -> tuple[Path, ...]:
    try:
        root = RAW_DB_ROOTS[model]
    except KeyError as exc:
        raise ValueError(f"no raw DB root configured for model: {model}") from exc
    return tuple(root / subdir / "raw_db.csv" for subdir in RAW_DB_SUBDIRS)

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
    prefill_batches, prefill_seq_lens, generation_batches, generation_seq_lens = selection
    return SuiteMatrixOverrides(
        prefill_batch_values=prefill_batches,
        prefill_seq_len_values=prefill_seq_lens,
        generation_batch_values=generation_batches,
        generation_seq_len_values=generation_seq_lens,
    )


def load_suites(tag: str, *, model: str, shape_selection: ShapeSelection | None = None) -> list:
    matrix_overrides = matrix_overrides_for_selection(shape_selection)
    return [
        load_suite(path, repo_root=REPO_ROOT, matrix_overrides=matrix_overrides)
        for path in suite_paths(tag, model)
    ]


# Prepared CSV controls. The expensive compose/estimate step writes excel_figure_data.csv and total.csv.
FIGURE_OUTPUT_ROOT = LATENCY_DIR / OUTPUT_FOLDER / "figures_prepare"
FIGURE_DATA_CSV_NAME = "excel_figure_data.csv"
TOTAL_CSV_NAME = "total.csv"
USE_FIGURE_DATA_CACHE = True
FORCE_REBUILD_FIGURE_DATA = True

# Measurement and aggregation controls.
# With METRIC="fpga_cycle", totals are sum(fpga_cycle * calls_per_forward).
METRIC = "fpga_cycle"
SELECT = "latest"
MISSING = "nan"  # Keep missing data visible while interpolation is enabled.
X_AXIS = "seq_len"
HUE_AXIS = "variant"
ROW_AXIS = "stage"
COL_AXIS = "batch"
STACK_BY = "name"
E2E_STACK_BY = "kind"
RELATIVE = True
RELATIVE_SCOPE = "x_tick"  # global, subplot, or x_tick

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
) -> pd.Series:
    mask = df["stage"].astype(str).eq(stage)
    if batches:
        mask &= pd.to_numeric(df["batch"], errors="coerce").isin(batches)
    if seq_lens:
        mask &= pd.to_numeric(df["seq_len"], errors="coerce").isin(seq_lens)
    return mask


def _target_shape_filter(
    *,
    prefill_batches: tuple[int, ...],
    prefill_seq_lens: tuple[int, ...],
    generation_batches: tuple[int, ...],
    generation_seq_lens: tuple[int, ...],
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
        )

    return _filter


E2E_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=E2E_PREFILL_BATCHES,
    prefill_seq_lens=E2E_PREFILL_SEQ_LENS,
    generation_batches=E2E_GENERATION_BATCHES,
    generation_seq_lens=E2E_GENERATION_SEQ_LENS,
)
GEMM_ONLY_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=GEMM_ONLY_PREFILL_BATCHES,
    prefill_seq_lens=GEMM_ONLY_PREFILL_SEQ_LENS,
    generation_batches=GEMM_ONLY_GENERATION_BATCHES,
    generation_seq_lens=GEMM_ONLY_GENERATION_SEQ_LENS,
)
ENERGY_SHAPE_FILTER = _target_shape_filter(
    prefill_batches=ENERGY_PREFILL_BATCHES,
    prefill_seq_lens=ENERGY_PREFILL_SEQ_LENS,
    generation_batches=ENERGY_GENERATION_BATCHES,
    generation_seq_lens=ENERGY_GENERATION_SEQ_LENS,
)
PLOT_ROW_FILTERS = (E2E_SHAPE_FILTER,)


def exclude_c4_alone(df):
    return df["variant"].ne(C4_ALONE_VARIANT)


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


# Interpolation/estimation controls. Prepared data uses measured + estimated rows when enabled.
LATENCY_ESTIMATE = LatencyEstimateOptions(
    model="auto_shape",
    min_train_rows=3,
    fallback="nearest_scale",
    warn_extrapolation=True,
)

# Optional raw DB latency normalization rules. These match raw DB rows before
# compose maps measurements back to suite cases.
LATENCY_SCALE_RULES = []

# Target-case area normalization rules. These match composed suite-case columns
# after raw measurements are mapped back to C1/C2/C3/C4 variants.
TH16_FP_TCU_CELL_AREA=276593.0284
FPINT_MXU_CELL_AREA=693436.0606
AREA_RATIO=FPINT_MXU_CELL_AREA / TH16_FP_TCU_CELL_AREA
CASE_LATENCY_SCALE_RULES = [
    # C1 GEMM scale is 1.0, so no rule is needed.
    LatencyScaleRule(
        "C2_gemm_area_norm",
        {"kind": "gemm", "variant": "attn_sgemm_tcu_fpint_gemm_naive_spinquant"},
        1+AREA_RATIO,
    ),
    LatencyScaleRule(
        "C3_gemm_area_norm",
        {"kind": "gemm", "variant": "all_fpint_gemm_naive_spinquant"},
        AREA_RATIO,
    ),
    LatencyScaleRule(
        "C4_gemm_area_norm",
        {"kind": "gemm", "variant": (C4_ALONE_VARIANT, C4_FUSED_VARIANT)},
        AREA_RATIO,
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
    return plot_script.write_latency_figure_data_csv(deps, result)


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


def warn_interpolation_estimates(composed: pd.DataFrame | None, *, context: str) -> None:
    if composed is None or composed.empty or "estimate_mode" not in composed.columns:
        return
    modes = composed["estimate_mode"].fillna("").astype(str)
    if "compose_status" in composed.columns:
        estimated = composed["compose_status"].astype(str).eq("estimated")
    else:
        estimated = modes.ne("")
    subset = composed[estimated & modes.eq("interpolation")]
    if subset.empty:
        return
    groups = _join_unique(subset.get("estimate_group", pd.Series(dtype=str)))
    case_ids = _join_unique(subset.get("case_id", pd.Series(dtype=str)))
    details = [f"{context}: latency interpolation used for {len(subset)} estimated row(s)"]
    if groups:
        details.append(f"groups={groups}")
    if case_ids:
        details.append(f"case_ids={case_ids}")
    warnings.warn("; ".join(details), RuntimeWarning, stacklevel=2)


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
    final_total = pd.to_numeric(total.get("total_latency_us"), errors="coerce")
    total["final_total_metric_value"] = final_total
    if METRIC == "fpga_cycle":
        total["final_total_fpga_cycles"] = final_total
    else:
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
        "metric", "stage", "batch", "seq_len", "variant",
        "final_total_metric_value", "final_total_fpga_cycles", "final_total_latency_us", "final_total_latency_s", "final_result_source",
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
    plot_row_filters = tuple(PLOT_ROW_FILTERS if row_filters is None else row_filters)
    if not include_c4_alone and exclude_c4_alone not in plot_row_filters:
        plot_row_filters = (*plot_row_filters, exclude_c4_alone)
    suites = load_suites(suite_tag, model=model, shape_selection=shape_selection)
    raw_dbs = raw_dbs_for_model(model)
    options = SuiteBarPlotOptions(
        raw_dbs=raw_dbs,
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
        latency_scale_rules=tuple(LATENCY_SCALE_RULES),
        case_latency_scale_rules=tuple(
            CASE_LATENCY_SCALE_RULES
            if case_latency_scale_rules is None
            else case_latency_scale_rules
        ),
        latency_estimate=LATENCY_ESTIMATE,
        row_filters=plot_row_filters,
    )
    return suites, options


def export_suite_figure_data(
    *,
    model: str,
    suite_tag: str,
    out_name: str,
    stacked: bool,
    stack_by: str = STACK_BY,
    include_c4_alone: bool = False,
    row_filters: tuple | None = None,
    shape_selection: ShapeSelection | None = E2E_SHAPE_SELECTION,
    case_latency_scale_rules: tuple[LatencyScaleRule, ...] | None = None,
) -> PlotRunResult:
    out_dir = FIGURE_OUTPUT_ROOT / out_name
    suites_in = suite_paths(suite_tag, model)
    if not suites_in:
        raise FileNotFoundError(f"no suite YAMLs found for SUITE_SOURCE={SUITE_SOURCE!r}, suite_tag={suite_tag!r}")
    missing_inputs = [path for path in [*suites_in, *raw_dbs_for_model(model)] if not path.exists()]
    if missing_inputs:
        raise FileNotFoundError("missing plot inputs:\n" + "\n".join(str(path) for path in missing_inputs))
    suites, options = _make_suite_options(
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
    versions = prepare_suite_bar_data_versions(suites, options)
    plot_input = versions.final
    warn_interpolation_estimates(plot_input.composed, context=out_name)
    result = PlotRunResult(
        tag=suite_tag,
        out_dir=out_dir,
        suites=suites,
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
    include_c4_alone: bool = False,
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

    plot_input = source.versions.estimated or source.versions.base
    out_dir = FIGURE_OUTPUT_ROOT / out_name
    options = replace(
        source.options,
        out_dir=out_dir,
        latency_scale_rules=(),
        case_latency_scale_rules=(),
    )
    warn_interpolation_estimates(plot_input.composed, context=out_name)
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
) -> PlotRunResult:
    if source.versions is not None and not LATENCY_SCALE_RULES:
        return export_no_area_norm_figure_data(source, out_name=out_name)
    return load_or_export_suite_figure_data(
        model=model,
        suite_tag=suite_tag,
        out_name=out_name,
        stacked=stacked,
        stack_by=stack_by,
        include_c4_alone=False,
        case_latency_scale_rules=(),
    )


GEMM_ONLY_FILTERS = (GEMM_ONLY_SHAPE_FILTER, lambda df: df["kind"].eq("gemm"), exclude_c4_alone)
main_all_result: PlotRunResult | None = None

# Energy per token.
ENERGY_IDLE_POWER_W = FPGA_IDLE_POWER
INCLUDE_IDLE_POWER = False
ENERGY_POWER_METRICS = ("power_avg_W", "power_vcc_avg_W", "power_dynamic_avg_W")
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
) -> pd.DataFrame:
    if (
        main_result is not None
        and main_result.composed is not None
        and _shape_selection_matches(E2E_SHAPE_SELECTION, ENERGY_SHAPE_SELECTION)
    ):
        return main_result.composed

    rebuilt = export_suite_figure_data(
        model=model,
        suite_tag=suite_tag,
        out_name=out_name,
        stacked=False,
        include_c4_alone=False,
        row_filters=(ENERGY_SHAPE_FILTER,),
        shape_selection=ENERGY_SHAPE_SELECTION,
    )
    return rebuilt.composed


def export_energy_figure_data_pair(
    *,
    model: str,
    suite_tag: str,
    main_result: PlotRunResult | None,
    out_name: str,
    stacked_out_name: str,
    power_metric: str,
    fpga_period_s: float = ENERGY_FPGA_PERIOD_S,
    force_rebuild: bool | None = None,
) -> tuple[str, str]:
    """Build flat and stacked energy tables from one shared energy calculation."""
    force = FORCE_REBUILD_FIGURE_DATA if force_rebuild is None else force_rebuild
    output_names = (out_name, stacked_out_name)
    output_paths = tuple(figure_data_path(name) for name in output_names)
    cached = tuple(USE_FIGURE_DATA_CACHE and path.exists() and not force for path in output_paths)
    if all(cached):
        return "cache", "cache"

    composition_out_name = next(name for name, is_cached in zip(output_names, cached) if not is_cached)
    composed = _energy_composed_rows(
        model=model,
        suite_tag=suite_tag,
        main_result=main_result,
        out_name=composition_out_name,
    )
    records = list(composed.to_dict(orient="records")) if hasattr(composed, "to_dict") else list(composed)
    rows = energy_rows_from_records(
        records,
        raw_dbs_for_model(model),
        idle_power_w=ENERGY_IDLE_POWER_W,
        include_idle_power=INCLUDE_IDLE_POWER,
        power_metric=power_metric,
        fpga_period_s=fpga_period_s,
    )
    totals = summarize_energy_rows(rows)
    label_maps = plot_label_maps(include_c4_alone=False)

    summary = add_relative_energy_values(totals, relative_scope=RELATIVE_SCOPE)
    result = plot_script.EnergyExcelResult(
        summary=pd.DataFrame(summary),
        figure_path=FIGURE_OUTPUT_ROOT / out_name / "energy_per_token.png",
    )
    plot_script.write_energy_figure_data_csv(result, label_maps=label_maps)

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
    plot_script.write_energy_stacked_figure_data_csv(
        result,
        label_maps=label_maps,
        stack_by=E2E_STACK_BY,
    )
    return "rebuilt", "rebuilt"

BUILD_LLAMA_COMPARE = False
LLAMA_COMPARE_OUT_DIR = FIGURE_OUTPUT_ROOT / "llama_compare"
LLAMA_COMPARE_CSV = LLAMA_COMPARE_OUT_DIR / "c1_vs_c4_speedup_batch1.csv"
LLAMA_COMPARE_CACHE_VERSION = "raw_roots_v3_fpga_cycle_forward_calls"
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
        label_maps=plot_label_maps(include_c4_alone=False),
        value_orders=VALUE_ORDERS,
        latency_scale_rules=tuple(LATENCY_SCALE_RULES),
        case_latency_scale_rules=tuple(CASE_LATENCY_SCALE_RULES),
        latency_estimate=LATENCY_ESTIMATE,
        row_filters=(),
    )
    versions = prepare_suite_bar_data_versions(suites, options)
    warn_interpolation_estimates(versions.final.composed, context=f"llama_compare:{model_spec['model']}")
    plot_data = versions.final.plot_data.copy()
    plot_data["batch"] = _numeric_int_column(plot_data, "batch")
    plot_data["seq_len"] = _numeric_int_column(plot_data, "seq_len")
    plot_data["total_fpga_cycles"] = pd.to_numeric(plot_data["total_latency_us"], errors="coerce")

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
            total_fpga_cycles=("total_fpga_cycles", "sum"),
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
            c1_total_fpga_cycles = float(c1["total_fpga_cycles"])
            c4_total_fpga_cycles = float(c4["total_fpga_cycles"])
            if not math.isfinite(c1_total_fpga_cycles) or c1_total_fpga_cycles <= 0.0:
                raise ValueError(f"invalid C1 total fpga cycles for {model_spec['model']} {stage} seq_len={seq_len}: {c1_total_fpga_cycles}")
            if not math.isfinite(c4_total_fpga_cycles) or c4_total_fpga_cycles <= 0.0:
                raise ValueError(f"invalid C4 total fpga cycles for {model_spec['model']} {stage} seq_len={seq_len}: {c4_total_fpga_cycles}")
            record = {
                "model": model_spec["model"],
                "display_model": model_spec["display_model"],
                "stage": stage,
                "stage_label": LABEL_MAPS["stage"].get(stage, stage),
                "batch": LLAMA_COMPARE_BATCH,
                "seq_len": seq_len,
                "seq_label": LLAMA_COMPARE_SEQ_LABELS[seq_len],
                "seq_rank": LLAMA_COMPARE_SEQ_ORDER.index(seq_len),
                "c1_total_fpga_cycles": c1_total_fpga_cycles,
                "c4_total_fpga_cycles": c4_total_fpga_cycles,
                "c1_over_c4_speedup": c1_total_fpga_cycles / c4_total_fpga_cycles,
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


def main() -> int:
    global main_all_result

    print(f"target model: {TARGET_MODEL}")
    print(f"target models: {TARGET_MODELS}")
    print(f"suite source: {SUITE_SOURCE}")
    print(f"prefill batches: {E2E_PREFILL_BATCHES}, prefill seq_lens: {E2E_PREFILL_SEQ_LENS}")
    print(f"generation batches: {E2E_GENERATION_BATCHES}, generation seq_lens: {E2E_GENERATION_SEQ_LENS}")

    prepared_outputs = []
    for model in TARGET_MODELS:
        suite_tag = suite_tag_for_model(model)
        main_name = main_out_name(model)
        no_area_norm_name = e2e_no_area_norm_out_name(model)
        e2e_stacked_name = e2e_stacked_out_name(model)
        no_area_norm_stacked_name = e2e_no_area_norm_stacked_out_name(model)
        gemm_name = gemm_only_out_name(model)

        print(f"model: {model}")
        print(f"suite tag: {suite_tag}")

        main_all_result = load_or_export_suite_figure_data(
            model=model,
            suite_tag=suite_tag,
            out_name=main_name,
            stacked=False,
            include_c4_alone=False,
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
            include_c4_alone=False,
        )
        print(f"{model} E2E stacked figure data source: {e2e_stacked_result.cache_status}")

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
            include_c4_alone=False,
        )
        print(f"{model} GEMM-only figure data source: {main_all_gemm_only_result.cache_status}")

        energy_names = []
        energy_stacked_names = []
        for power_metric in ENERGY_POWER_METRICS:
            energy_name = energy_out_name(model, power_metric)
            energy_stacked_name = energy_stacked_out_name(model, power_metric)
            energy_cache_status, energy_stacked_cache_status = export_energy_figure_data_pair(
                model=model,
                suite_tag=suite_tag,
                main_result=main_all_result,
                out_name=energy_name,
                stacked_out_name=energy_stacked_name,
                power_metric=power_metric,
            )
            print(f"{model} {power_metric} energy figure data source: {energy_cache_status}")
            energy_names.append(energy_name)

            print(
                f"{model} {power_metric} stacked energy figure data source: "
                f"{energy_stacked_cache_status}"
            )
            energy_stacked_names.append(energy_stacked_name)

        prepared_outputs.extend(
            [
                figure_data_path(main_name),
                total_data_path(main_name),
                figure_data_path(no_area_norm_name),
                total_data_path(no_area_norm_name),
                figure_data_path(e2e_stacked_name),
                total_data_path(e2e_stacked_name),
                figure_data_path(no_area_norm_stacked_name),
                total_data_path(no_area_norm_stacked_name),
                figure_data_path(gemm_name),
                total_data_path(gemm_name),
                *(figure_data_path(energy_name) for energy_name in energy_names),
                *(figure_data_path(energy_name) for energy_name in energy_stacked_names),
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
