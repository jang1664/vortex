#!/usr/bin/env python3
"""Analyze Vortex TCU synthesis reports with hwexplorer.

The default scan root is::

    build/hw/syn/synopsys/tcu

For every discovered ``14_<design>.mapped.area.rpt``, the script pairs the
corresponding power and timing reports and writes run summaries, functional
breakdowns, and normalized module-family instance counts.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import logging
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


HERE = Path(__file__).resolve().parent
VORTEX_ROOT = HERE.parents[1]
DEFAULT_BUILD_ROOT = VORTEX_ROOT / "build/hw/syn/synopsys/tcu"
DEFAULT_OUTPUT_DIR = HERE / "results"

# The local hwexplorer checkout is a sibling of the Vortex repository.  Keep
# an installed package ahead of it, but make the sibling checkout available
# when the conda environment does not install hwexplorer as a package.
HWEXPLORER_CHECKOUT = VORTEX_ROOT.parent / "hwexplorer"
if HWEXPLORER_CHECKOUT.is_dir() and str(HWEXPLORER_CHECKOUT) not in sys.path:
    sys.path.append(str(HWEXPLORER_CHECKOUT))

logging.getLogger("hwexplorer").setLevel(logging.WARNING)

try:
    import pandas as pd
    from hwexplorer.report_parser import (
        SynopsysDesignCompilerAreaParser,
        SynopsysDesignCompilerPowerParser,
        SynopsysDesignCompilerTimingParser,
    )
except ImportError as exc:  # pragma: no cover - exercised only on a bad setup
    raise SystemExit(
        "Unable to import pandas/hwexplorer. Activate the requested conda "
        "environment first, for example:\n"
        "  conda activate vortex\n"
        "  python analysis_workspace/tcu/analyze_tcu.py\n"
        f"Import error: {exc}"
    )


AREA_SUFFIX = ".mapped.area.rpt"
POWER_SUFFIX = ".mapped.power.rpt"
TIMING_SUFFIX = ".mapped.timing.rpt"


@dataclass(frozen=True)
class RunReports:
    """Report paths belonging to one synthesis run."""

    run_id: str
    design: str
    reports_dir: Path
    area_report: Path
    power_report: Path
    timing_report: Path


@dataclass(frozen=True)
class FunctionalPattern:
    """A precise hierarchy-path pattern used for TCU component counts."""

    category: str
    description: str
    regex: re.Pattern


FUNCTIONAL_PATTERNS: Tuple[FunctionalPattern, ...] = (
    FunctionalPattern(
        "tcu_fp",
        "Floating-point TCU block",
        re.compile(r"/g_blocks_\d+__tcu_fp$"),
    ),
    FunctionalPattern(
        "tcu_int",
        "Integer TCU block",
        re.compile(r"/g_blocks_\d+__tcu_int$"),
    ),
    FunctionalPattern(
        "fp_fedp",
        "Floating-point FEDP",
        re.compile(r"/g_blocks_\d+__tcu_fp/g_i_\d+__g_j_\d+__fedp$"),
    ),
    FunctionalPattern(
        "int_fedp",
        "Integer FEDP",
        re.compile(r"/g_blocks_\d+__tcu_int/g_i_\d+__g_j_\d+__fedp$"),
    ),
    FunctionalPattern(
        "bhf_fp16_multiplier",
        "BHF FP16 multiplier",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_prod_\d+__fp16_mul$"),
    ),
    FunctionalPattern(
        "bhf_bf16_multiplier",
        "BHF BF16 multiplier",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_prod_\d+__bf16_mul$"),
    ),
    FunctionalPattern(
        "dw_fp16_input_converter",
        "DesignWare FEDP FP16-to-FP32 input converter",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_cvt_\d+__cvt_(?:row|col)_fp16$"),
    ),
    FunctionalPattern(
        "dw_bf16_input_converter",
        "DesignWare FEDP BF16-to-FP32 input converter",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_cvt_\d+__cvt_(?:row|col)_bf16$"),
    ),
    FunctionalPattern(
        "product_pipeline",
        "Post-multiply product pipeline",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_prod_\d+__pipe_mult$"),
    ),
    FunctionalPattern(
        "bhf_reduction_adder",
        "BHF floating-point reduction adder",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_red_tree_\d+__g_add_\d+__reduce_add$"),
    ),
    FunctionalPattern(
        "dw_reduction_pipeline",
        "DesignWare FEDP reduction pipeline",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/g_red_tree_\d+__g_add_\d+__pipe_red$"),
    ),
    FunctionalPattern(
        "final_adder",
        "Floating-point final C accumulator",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/final_add$"),
    ),
    FunctionalPattern(
        "c_input_conversion",
        "FP32 C input recoding",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/conv_c$"),
    ),
    FunctionalPattern(
        "c_pipeline",
        "C alignment pipeline",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/pipe_c$"),
    ),
    FunctionalPattern(
        "format_pipeline",
        "Source-format alignment pipeline",
        re.compile(r"/g_blocks_\d+__tcu_fp/.*/pipe_fmt_s$"),
    ),
)


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse Vortex TCU area, power, timing, and hierarchy reports with hwexplorer."
    )
    parser.add_argument(
        "--build-root",
        type=Path,
        default=DEFAULT_BUILD_ROOT,
        help=f"TCU synthesis root to scan (default: {DEFAULT_BUILD_ROOT})",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory for CSV/JSON/Markdown results (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--run",
        action="append",
        default=[],
        metavar="GLOB",
        help="Analyze only run IDs matching this glob. Repeatable; default is all runs.",
    )
    parser.add_argument(
        "--list-runs",
        action="store_true",
        help="List discovered runs and exit without parsing reports.",
    )
    parser.add_argument(
        "--raw-hierarchy",
        action="store_true",
        help="Also write hierarchy.csv with every area hierarchy row and matched power.",
    )
    parser.add_argument(
        "--require-power",
        action="store_true",
        help="Fail when a selected run does not have its matching power report.",
    )
    return parser.parse_args(argv)


def resolve_path(path: Path) -> Path:
    """Resolve CLI paths relative to the Vortex repository."""

    return path.resolve() if path.is_absolute() else (VORTEX_ROOT / path).resolve()


def extract_design(area_report: Path) -> str:
    name = area_report.name
    if not name.startswith("14_") or not name.endswith(AREA_SUFFIX):
        raise ValueError(f"unexpected area report name: {name}")
    return name[len("14_") : -len(AREA_SUFFIX)]


def discover_runs(build_root: Path, run_globs: Sequence[str]) -> List[RunReports]:
    runs: List[RunReports] = []
    if not build_root.is_dir():
        raise SystemExit(f"TCU build root does not exist: {build_root}")

    for area_report in sorted(build_root.rglob("14_*.mapped.area.rpt")):
        design = extract_design(area_report)
        reports_dir = area_report.parent
        try:
            run_path = reports_dir.parent.relative_to(build_root)
        except ValueError:
            continue
        run_id = run_path.as_posix()
        if run_globs and not any(
            fnmatch.fnmatch(run_id, pattern) for pattern in run_globs
        ):
            continue
        runs.append(
            RunReports(
                run_id=run_id,
                design=design,
                reports_dir=reports_dir,
                area_report=area_report,
                power_report=reports_dir / f"18_{design}{POWER_SUFFIX}",
                timing_report=reports_dir / f"12_{design}{TIMING_SUFFIX}",
            )
        )
    return runs


def optional_float(value: Any) -> Optional[float]:
    if value is None or pd.isna(value):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def optional_int(value: Any) -> Optional[int]:
    number = optional_float(value)
    return None if number is None else int(number)


def module_family(module_name: Any) -> str:
    """Remove only synthesis-generated uniquification suffixes.

    Parameter-bearing names such as ``VX_shift_register_33_0_1_0_127`` keep
    their structural parameters and lose the last instance ID.  Hashed Vortex
    module names such as ``VX_tcu_fp_h_805_242_943`` collapse to ``VX_tcu_fp``.
    """

    name = "" if module_name is None else str(module_name).strip()
    if not name:
        return "<unknown>"
    name = re.sub(r"_h(?:_\d+)+$", "", name)
    name = re.sub(r"_\d+$", "", name)
    return name


def load_area(run: RunReports):
    db = SynopsysDesignCompilerAreaParser().load(str(run.area_report))
    key = db.HIERARCHY_KEY
    if key not in db.tables or db.tables[key].empty:
        raise ValueError(f"area hierarchy is missing or empty: {run.area_report}")
    return db, db.tables[key].copy()


def load_power(run: RunReports):
    if not run.power_report.is_file():
        return None, pd.DataFrame()
    db = SynopsysDesignCompilerPowerParser().load(str(run.power_report))
    key = db.HIERARCHY_KEY
    if key not in db.tables:
        return db, pd.DataFrame()
    return db, db.tables[key].copy()


def load_timing(run: RunReports) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        "timing_report": str(run.timing_report),
        "timing_available": run.timing_report.is_file(),
        "wns_ns": None,
        "max_data_arrival_time_ns": None,
        "worst_reported_path_slack_ns": None,
        "timing_path_count": 0,
    }
    if not run.timing_report.is_file():
        return result

    db = SynopsysDesignCompilerTimingParser().load(str(run.timing_report))
    result["wns_ns"] = optional_float(db.metadata.get("wns"))
    result["max_data_arrival_time_ns"] = optional_float(
        db.metadata.get("max_data_arrival_time")
    )
    paths = db.tables.get(db.PATHS_KEY, pd.DataFrame())
    result["timing_path_count"] = len(paths)
    if not paths.empty and "slack" in paths.columns:
        result["worst_reported_path_slack_ns"] = optional_float(paths["slack"].min())
    return result


def merge_hierarchies(area_df, power_df, run_id: str):
    area = area_df.rename(columns={"percent": "area_percent"}).copy()
    power_columns = [
        "full_path",
        "switch_power",
        "internal_power",
        "leak_power",
        "power",
        "percent",
    ]
    if power_df.empty:
        merged = area.copy()
        for column in power_columns[1:-1]:
            merged[column] = float("nan")
        merged["power_percent"] = float("nan")
    else:
        power = power_df[power_columns].rename(columns={"percent": "power_percent"})
        merged = area.merge(power, how="left", on="full_path", validate="one_to_one")

    merged.insert(0, "run_id", run_id)
    merged["local_area"] = (
        merged["comb_area"].fillna(0.0)
        + merged["non_comb_area"].fillna(0.0)
        + merged["blackbox_area"].fillna(0.0)
    )
    merged["module_family"] = merged["module_name"].map(module_family)
    return merged


def top_power(power_df) -> Dict[str, Any]:
    result = {
        "switch_power_mw": None,
        "internal_power_mw": None,
        "dynamic_power_mw": None,
        "leakage_power_uw": None,
        "leakage_power_mw": None,
        "total_power_mw": None,
    }
    if power_df.empty:
        return result
    roots = power_df[power_df["depth"] == 0]
    row = roots.iloc[0] if not roots.empty else power_df.iloc[0]
    switch = optional_float(row.get("switch_power"))
    internal = optional_float(row.get("internal_power"))
    leakage_uw = optional_float(row.get("leak_power"))
    result.update(
        {
            "switch_power_mw": switch,
            "internal_power_mw": internal,
            "dynamic_power_mw": (
                None if switch is None or internal is None else switch + internal
            ),
            "leakage_power_uw": leakage_uw,
            "leakage_power_mw": (None if leakage_uw is None else leakage_uw / 1000.0),
            "total_power_mw": optional_float(row.get("power")),
        }
    )
    return result


def build_summary(
    run: RunReports,
    area_db,
    area_df,
    power_db,
    power_df,
) -> Dict[str, Any]:
    metadata = area_db.metadata
    total_area = optional_float(metadata.get("total_cell_area"))
    result: Dict[str, Any] = {
        "run_id": run.run_id,
        "design": metadata.get("design_name") or run.design,
        "tool_version": metadata.get("tool_version"),
        "area_report_date": metadata.get("report_date"),
        "power_scenario": None
        if power_db is None
        else power_db.metadata.get("scenario_s"),
        "area_report": str(run.area_report),
        "power_report": str(run.power_report),
        "power_available": not power_df.empty,
        "total_cell_area_um2": total_area,
        "total_cell_area_mm2": None if total_area is None else total_area / 1e6,
        "combinational_area_um2": optional_float(metadata.get("combinational_area")),
        "noncombinational_area_um2": optional_float(
            metadata.get("noncombinational_area")
        ),
        "buf_inv_area_um2": optional_float(metadata.get("buf_inv_area")),
        "macro_black_box_area_um2": optional_float(
            metadata.get("macro_black_box_area")
        ),
        "core_area_um2": optional_float(metadata.get("core_area")),
        "utilization_ratio": optional_float(metadata.get("utilization_ratio")),
        "num_ports": optional_int(metadata.get("num_ports")),
        "num_nets": optional_int(metadata.get("num_nets")),
        "num_cells": optional_int(metadata.get("num_cells")),
        "num_combinational_cells": optional_int(
            metadata.get("num_combinational_cells")
        ),
        "num_sequential_cells": optional_int(metadata.get("num_sequential_cells")),
        "num_macros": optional_int(metadata.get("num_macros")),
        "num_buf_inv": optional_int(metadata.get("num_buf_inv")),
        "hierarchical_instance_rows": max(0, len(area_df) - 1),
        "power_hierarchy_rows": max(0, len(power_df) - 1),
    }
    result.update(top_power(power_df))
    result.update(load_timing(run))
    return result


def sum_or_none(series) -> Optional[float]:
    values = series.dropna()
    return None if values.empty else float(values.sum())


def mean_or_none(series) -> Optional[float]:
    values = series.dropna()
    return None if values.empty else float(values.mean())


def functional_breakdown(
    run_id: str,
    area_df,
    power_df,
    top_area: Optional[float],
    top_total_power: Optional[float],
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    area_paths = area_df["full_path"].astype(str)
    power_paths = (
        pd.Series([], dtype=str)
        if power_df.empty
        else power_df["full_path"].astype(str)
    )

    for pattern in FUNCTIONAL_PATTERNS:
        area_nodes = area_df[
            area_paths.map(lambda path: pattern.regex.search(path) is not None)
        ]
        power_nodes = (
            power_df
            if power_df.empty
            else power_df[
                power_paths.map(lambda path: pattern.regex.search(path) is not None)
            ]
        )
        global_area = float(area_nodes["area"].sum()) if not area_nodes.empty else 0.0
        local_area = (
            float(
                (
                    area_nodes["comb_area"].fillna(0.0)
                    + area_nodes["non_comb_area"].fillna(0.0)
                    + area_nodes["blackbox_area"].fillna(0.0)
                ).sum()
            )
            if not area_nodes.empty
            else 0.0
        )
        total_power = (
            float(power_nodes["power"].sum()) if not power_nodes.empty else None
        )
        rows.append(
            {
                "run_id": run_id,
                "category": pattern.category,
                "description": pattern.description,
                "instance_count": len(area_nodes),
                "power_instance_count": len(power_nodes),
                "global_area_sum_um2": global_area,
                "global_area_mean_um2": (
                    None if area_nodes.empty else float(area_nodes["area"].mean())
                ),
                "local_area_sum_um2": local_area,
                "area_percent_of_top": (
                    None if not top_area else 100.0 * global_area / top_area
                ),
                "switch_power_sum_mw": (
                    None
                    if power_nodes.empty
                    else float(power_nodes["switch_power"].sum())
                ),
                "internal_power_sum_mw": (
                    None
                    if power_nodes.empty
                    else float(power_nodes["internal_power"].sum())
                ),
                "leakage_power_sum_uw": (
                    None
                    if power_nodes.empty
                    else float(power_nodes["leak_power"].sum())
                ),
                "total_power_sum_mw": total_power,
                "total_power_mean_mw": (
                    None if power_nodes.empty else float(power_nodes["power"].mean())
                ),
                "power_percent_of_top": (
                    None
                    if total_power is None or not top_total_power
                    else 100.0 * total_power / top_total_power
                ),
            }
        )
    return rows


def module_instance_breakdown(hierarchy_df) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for (run_id, family), group in hierarchy_df.groupby(
        ["run_id", "module_family"], sort=False, dropna=False
    ):
        rows.append(
            {
                "run_id": run_id,
                "module_family": family,
                "instance_count": len(group),
                "global_area_sum_um2": float(group["area"].sum()),
                "global_area_mean_um2": float(group["area"].mean()),
                "global_area_min_um2": float(group["area"].min()),
                "global_area_max_um2": float(group["area"].max()),
                "local_area_sum_um2": float(group["local_area"].sum()),
                "power_instance_count": int(group["power"].notna().sum()),
                "switch_power_sum_mw": sum_or_none(group["switch_power"]),
                "internal_power_sum_mw": sum_or_none(group["internal_power"]),
                "leakage_power_sum_uw": sum_or_none(group["leak_power"]),
                "total_power_sum_mw": sum_or_none(group["power"]),
                "total_power_mean_mw": mean_or_none(group["power"]),
            }
        )
    return rows


def json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    if isinstance(value, tuple):
        return [json_safe(item) for item in value]
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
    except (TypeError, ValueError):
        pass
    if hasattr(value, "item"):
        return value.item()
    return value


def markdown_value(value: Any, digits: int = 4) -> str:
    if value is None or pd.isna(value):
        return "N/A"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, int):
        return f"{value:,}"
    if isinstance(value, float):
        return f"{value:,.{digits}f}"
    return str(value).replace("|", "\\|")


def render_markdown(
    summaries: Sequence[Dict[str, Any]],
    functional_rows: Sequence[Dict[str, Any]],
    build_root: Path,
) -> str:
    lines = [
        "# TCU Synthesis Analysis",
        "",
        f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        f"Build root: `{build_root}`",
        "",
        "## Run summary",
        "",
        "| Run | Area (um^2) | Area (mm^2) | Cells | Seq. cells | Total power (mW) | WNS (ns) | Worst listed slack (ns) |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summaries:
        lines.append(
            "| {run} | {area} | {area_mm2} | {cells} | {seq} | {power} | {wns} | {slack} |".format(
                run=markdown_value(row["run_id"]),
                area=markdown_value(row["total_cell_area_um2"]),
                area_mm2=markdown_value(row["total_cell_area_mm2"], 6),
                cells=markdown_value(row["num_cells"], 0),
                seq=markdown_value(row["num_sequential_cells"], 0),
                power=markdown_value(row["total_power_mw"]),
                wns=markdown_value(row["wns_ns"]),
                slack=markdown_value(row["worst_reported_path_slack_ns"]),
            )
        )

    by_run: Dict[str, List[Dict[str, Any]]] = {}
    for row in functional_rows:
        if row["instance_count"] or row["power_instance_count"]:
            by_run.setdefault(row["run_id"], []).append(row)

    lines.extend(["", "## Functional hierarchy breakdown", ""])
    for summary in summaries:
        run_id = summary["run_id"]
        lines.extend(
            [
                f"### `{run_id}`",
                "",
                "| Category | Instances | Global area sum (um^2) | Mean area (um^2) | Top area share | Total power sum (mW) | Top power share |",
                "|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for row in by_run.get(run_id, []):
            lines.append(
                "| {category} | {count} | {area} | {mean} | {area_pct}% | {power} | {power_pct}% |".format(
                    category=markdown_value(row["category"]),
                    count=markdown_value(row["instance_count"], 0),
                    area=markdown_value(row["global_area_sum_um2"]),
                    mean=markdown_value(row["global_area_mean_um2"]),
                    area_pct=markdown_value(row["area_percent_of_top"]),
                    power=markdown_value(row["total_power_sum_mw"]),
                    power_pct=markdown_value(row["power_percent_of_top"]),
                )
            )
        lines.append("")

    lines.extend(
        [
            "## Interpretation notes",
            "",
            "- Area and power hierarchy values are cumulative subtree values. Summing parent and child categories together double-counts their descendants.",
            "- `local_area_sum_um2` in the CSV counts only area directly owned by the matched hierarchy rows and is safe for module-family accounting.",
            "- Synopsys power columns use mW for switching/internal/total power and uW for leakage power in these reports.",
            "- The current power reports warn that primary inputs and sequential outputs are not fully annotated; treat power as vectorless synthesis estimates.",
            "- `module_instances.csv` groups hierarchy rows after removing synthesis uniquification suffixes. It reports both cumulative global area and non-overlapping local area.",
        ]
    )
    return "\n".join(lines) + "\n"


def write_outputs(
    output_dir: Path,
    summaries: List[Dict[str, Any]],
    functional_rows: List[Dict[str, Any]],
    module_rows: List[Dict[str, Any]],
    hierarchies: List[Any],
    build_root: Path,
    raw_hierarchy: bool,
) -> List[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    summary_df = pd.DataFrame(summaries)
    functional_df = pd.DataFrame(functional_rows)
    module_df = pd.DataFrame(module_rows)

    summary_path = output_dir / "summary.csv"
    functional_path = output_dir / "functional_breakdown.csv"
    modules_path = output_dir / "module_instances.csv"
    json_path = output_dir / "analysis.json"
    markdown_path = output_dir / "analysis.md"

    summary_df.to_csv(summary_path, index=False)
    functional_df.to_csv(functional_path, index=False)
    module_df.to_csv(modules_path, index=False)
    payload = {
        "build_root": str(build_root),
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "summary": summaries,
        "functional_breakdown": functional_rows,
        "module_instances": module_rows,
    }
    json_path.write_text(
        json.dumps(json_safe(payload), indent=2, sort_keys=True) + "\n"
    )
    markdown_path.write_text(render_markdown(summaries, functional_rows, build_root))

    paths = [summary_path, functional_path, modules_path, json_path, markdown_path]
    if raw_hierarchy:
        hierarchy_path = output_dir / "hierarchy.csv"
        pd.concat(hierarchies, ignore_index=True).to_csv(hierarchy_path, index=False)
        paths.append(hierarchy_path)
    return paths


def analyze_runs(runs: Iterable[RunReports], require_power: bool):
    summaries: List[Dict[str, Any]] = []
    functional_rows: List[Dict[str, Any]] = []
    hierarchies: List[Any] = []

    for run in runs:
        print(f"[parse] {run.run_id}")
        area_db, area_df = load_area(run)
        power_db, power_df = load_power(run)
        if require_power and power_df.empty:
            raise SystemExit(f"power report is missing or empty: {run.power_report}")

        summary = build_summary(run, area_db, area_df, power_db, power_df)
        merged = merge_hierarchies(area_df, power_df, run.run_id)
        summaries.append(summary)
        hierarchies.append(merged)
        functional_rows.extend(
            functional_breakdown(
                run.run_id,
                area_df,
                power_df,
                summary["total_cell_area_um2"],
                summary["total_power_mw"],
            )
        )

    hierarchy_df = pd.concat(hierarchies, ignore_index=True)
    module_rows = module_instance_breakdown(hierarchy_df)
    module_rows.sort(
        key=lambda row: (
            row["run_id"],
            -row["local_area_sum_um2"],
            row["module_family"],
        )
    )
    return summaries, functional_rows, module_rows, hierarchies


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    build_root = resolve_path(args.build_root)
    output_dir = resolve_path(args.output_dir)
    runs = discover_runs(build_root, args.run)

    if args.list_runs:
        if not runs:
            print(f"No runs found under {build_root}")
            return 1
        for run in runs:
            print(
                f"{run.run_id}\tarea=yes\t"
                f"power={'yes' if run.power_report.is_file() else 'no'}\t"
                f"timing={'yes' if run.timing_report.is_file() else 'no'}"
            )
        return 0

    if not runs:
        patterns = ", ".join(args.run) if args.run else "<all>"
        raise SystemExit(
            f"No TCU area reports found under {build_root} for run pattern(s): {patterns}"
        )

    summaries, functional_rows, module_rows, hierarchies = analyze_runs(
        runs, args.require_power
    )
    paths = write_outputs(
        output_dir,
        summaries,
        functional_rows,
        module_rows,
        hierarchies,
        build_root,
        args.raw_hierarchy,
    )

    print(f"\nAnalyzed {len(runs)} run(s).")
    for path in paths:
        print(f"[write] {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
