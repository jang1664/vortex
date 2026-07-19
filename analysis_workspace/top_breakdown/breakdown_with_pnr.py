"""Plot the standard Vortex area breakdown with selective-PnR floorplans.

This script deliberately reuses the legend definitions, colors, font sizes,
figure dimensions, legend order, and plotting function from ``breakdown.py``.
The DC hierarchy remains the auditable base. Each clean modeled block from
``selective_pnr_estimate.json`` replaces its hierarchy cell area with the
actual routed PnR core area for every matching occurrence. This includes
the placement whitespace and routing capacity reserved by the floorplan.

The selective-PnR flow does not provide a floorplan for every top-level block,
so the result is a hybrid estimate: DC cell area for unmodeled logic and routed
core area for modeled blocks. It is deliberately not labeled as either the
estimate's adjusted logical-cell area or its full-top hybrid core area.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
from typing import Any

import pandas as pd

import breakdown


HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
DEFAULT_ANALYSIS_RUN = (
    VORTEX
    / "build/hw/syn/synopsys/top_analysis/Vortex_axi_small_for_test"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the standard area breakdown with PnR corrections."
    )
    parser.add_argument(
        "--analysis-run",
        type=Path,
        default=Path(os.environ.get("TOP_ANALYSIS_RUN", DEFAULT_ANALYSIS_RUN)),
        help="Top-analysis run directory containing top/ and reports/.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="Override the top DC hierarchy area report.",
    )
    parser.add_argument(
        "--estimate",
        type=Path,
        help="Override reports/selective_pnr_estimate.json.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="Output directory. Default: top_breakdown/<analysis-run-name>_pnr.",
    )
    parser.add_argument(
        "--require-converged",
        action="store_true",
        help="Reject modeled blocks whose area search did not converge.",
    )
    return parser.parse_args()


def resolve_path(path: Path) -> Path:
    return path if path.is_absolute() else VORTEX / path


def load_estimate(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"selective-PnR estimate is missing: {path}")
    try:
        estimate = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read selective-PnR estimate {path}: {exc}") from exc
    required = {
        "top_logical_cell_area",
        "adjusted_logical_cell_area",
        "blocks",
    }
    missing = sorted(required - set(estimate))
    if missing:
        raise SystemExit(
            f"selective-PnR estimate {path} is missing: {', '.join(missing)}"
        )
    return estimate


def validate_estimate(
    estimate: dict[str, Any], dc_total_area: float, *, require_converged: bool
) -> list[dict[str, Any]]:
    top_area = float(estimate["top_logical_cell_area"])
    if not math.isclose(top_area, dc_total_area, rel_tol=1e-9, abs_tol=1e-3):
        raise SystemExit(
            "top report and selective-PnR estimate disagree on logical cell area: "
            f"{dc_total_area} != {top_area}"
        )

    blocks = list(estimate["blocks"])
    total_correction = sum(float(block.get("logical_correction", 0.0)) for block in blocks)
    adjusted = float(estimate["adjusted_logical_cell_area"])
    if not math.isclose(
        top_area + total_correction, adjusted, rel_tol=1e-9, abs_tol=1e-3
    ):
        raise SystemExit(
            "block logical corrections do not reproduce adjusted_logical_cell_area"
        )

    unconverged = [
        str(block.get("job_id", "<unknown>"))
        for block in blocks
        if block.get("aggregation_mode") == "modeled"
        and block.get("status") == "clean"
        and not block.get("search_converged", False)
    ]
    if unconverged and require_converged:
        raise SystemExit(
            "modeled PnR searches are not converged: " + ", ".join(unconverged)
        )
    if unconverged:
        print(
            "warning: plotting unconverged PnR search results: "
            + ", ".join(unconverged)
        )
    return blocks


def semantic_component(block: dict[str, Any]) -> str:
    """Map a modeled block to the paper-facing semantic component."""

    name = " ".join(
        [
            str(block.get("template_name", "")),
            str(block.get("job_id", "")),
            " ".join(str(path) for path in block.get("occurrence_paths", [])),
        ]
    ).lower()
    if any(token in name for token in ("xbar", "crossbar", "switch", "arb", "mux", "demux")):
        return "xbar"
    if "dma" in name:
        return "dma"
    if any(token in name for token in ("gemm", "mxu", "tensor_core")):
        return "mxu"
    if any(token in name for token in ("cache", "lmem", "tmem", "memory", "mem_")):
        return "memory"
    if any(token in name for token in ("alu", "lsu", "fpu", "sfu", "tcu", "issue", "schedule")):
        return "simt"
    return "residual"


def modeled_floorplan_area(block: dict[str, Any]) -> float:
    """Multiply one representative PnR core area by its instance count."""

    required = ("pnr_core_area", "instance_count")
    missing = [key for key in required if block.get(key) is None]
    if missing:
        raise SystemExit(
            f"clean modeled block {block.get('job_id', '<unknown>')} is missing: "
            + ", ".join(missing)
        )
    pnr_core_area = float(block["pnr_core_area"])
    instance_count = int(block["instance_count"])
    if pnr_core_area <= 0.0 or instance_count <= 0:
        raise SystemExit(
            f"clean modeled block {block.get('job_id', '<unknown>')} has "
            "a non-positive PnR core area or instance count"
        )
    return pnr_core_area * instance_count


def block_floorplan_correction(block: dict[str, Any]) -> float:
    """Return the delta for replacing hierarchy cell area with routed core area."""

    hierarchy_logical_area = block.get("hierarchy_logical_area")
    if hierarchy_logical_area is None:
        raise SystemExit(
            f"clean modeled block {block.get('job_id', '<unknown>')} is missing: "
            "hierarchy_logical_area"
        )
    return modeled_floorplan_area(block) - float(hierarchy_logical_area)


def pnr_component_corrections(blocks: list[dict[str, Any]]) -> dict[str, float]:
    corrections: dict[str, float] = {}
    for block in blocks:
        if (
            block.get("aggregation_mode") != "modeled"
            or block.get("status") != "clean"
        ):
            continue
        correction = block_floorplan_correction(block)
        component = semantic_component(block)
        corrections[component] = corrections.get(component, 0.0) + correction
    return corrections


def base_components(
    detail_sums: dict[str, float], hdf: pd.DataFrame
) -> dict[str, float]:
    """Build the same semantic components as breakdown.summarize_for_paper."""

    local_mem_area, _ = breakdown.exact_area(hdf, breakdown.LOCAL_MEM_PATTERN)
    mem_unit_area = detail_sums["memory unit"]
    if local_mem_area > mem_unit_area and not math.isclose(
        local_mem_area, mem_unit_area, rel_tol=1e-9, abs_tol=1e-6
    ):
        raise SystemExit(
            "local_mem area exceeds its mem_unit parent: "
            f"{local_mem_area} > {mem_unit_area}"
        )
    mem_overhead = max(0.0, mem_unit_area - local_mem_area)
    return {
        "simt": sum(detail_sums[label] for label in breakdown.SIMT_BUCKETS),
        "memory": local_mem_area
        + sum(detail_sums[label] for label in breakdown.MEMORY_BUCKETS),
        "mxu": detail_sums["GEMM unit (MXU compute)"],
        "dma": sum(detail_sums[label] for label in breakdown.DMA_BUCKETS),
        "xbar": mem_overhead
        + sum(detail_sums[label] for label in breakdown.XBAR_BUCKETS),
    }


def summarize_base(
    components: dict[str, float],
    total_area: float,
    legend_group: breakdown.LegendGroup,
) -> dict[str, float]:
    residual = [
        category for category in legend_group.categories if not category.components
    ]
    if len(residual) != 1:
        raise SystemExit(
            f"legend group {legend_group.name!r} must have one residual category"
        )
    summary = {
        category.label: sum(components[name] for name in category.components)
        for category in legend_group.categories
        if category.components
    }
    residual_label = residual[0].label
    summary[residual_label] = total_area - sum(summary.values())
    if summary[residual_label] < -1e-6:
        raise SystemExit("paper categories exceed total cell area")
    summary[residual_label] = max(0.0, summary[residual_label])
    return {
        category.label: summary[category.label]
        for category in legend_group.categories
    }


def apply_pnr_corrections(
    base_summary: dict[str, float],
    legend_group: breakdown.LegendGroup,
    corrections: dict[str, float],
) -> dict[str, float]:
    """Apply semantic PnR deltas while preserving legend order and total."""

    summary = dict(base_summary)
    residual = next(
        category for category in legend_group.categories if not category.components
    )
    for component, correction in corrections.items():
        target = next(
            (
                category
                for category in legend_group.categories
                if component in category.components
            ),
            residual,
        )
        summary[target.label] += correction
    if any(value < -1e-6 for value in summary.values()):
        raise SystemExit("PnR correction produced a negative breakdown category")
    return {
        category.label: max(0.0, summary[category.label])
        for category in legend_group.categories
    }


def write_detail_csv(
    detail_sums: dict[str, float],
    detail_counts: dict[str, int],
    blocks: list[dict[str, Any]],
    dc_total_area: float,
    hybrid_total_area: float,
    out_dir: Path,
) -> None:
    captured = sum(detail_sums.values())
    rows = [
        {
            "module": label,
            "num_matched": detail_counts[label],
            "dc_cell_area_um2": area,
            "pnr_floorplan_correction_um2": 0.0,
            "hybrid_area_um2": area,
        }
        for label, area in detail_sums.items()
        if area > 0.0 or detail_counts[label] > 0
    ]
    rows.append(
        {
            "module": "Other / residual glue",
            "num_matched": 0,
            "dc_cell_area_um2": max(0.0, dc_total_area - captured),
            "pnr_floorplan_correction_um2": 0.0,
            "hybrid_area_um2": max(0.0, dc_total_area - captured),
        }
    )
    for block in blocks:
        if (
            block.get("aggregation_mode") != "modeled"
            or block.get("status") != "clean"
        ):
            continue
        correction = block_floorplan_correction(block)
        rows.append(
            {
                "module": (
                    "PnR floorplan correction: "
                    f"{block.get('template_name', '<unknown>')}"
                ),
                "num_matched": int(block.get("instance_count", 0)),
                "dc_cell_area_um2": 0.0,
                "pnr_floorplan_correction_um2": correction,
                "hybrid_area_um2": correction,
            }
        )
    frame = pd.DataFrame(rows)
    frame["hybrid_area_mm2"] = frame["hybrid_area_um2"] / 1e6
    frame["percent"] = frame["hybrid_area_um2"] / hybrid_total_area * 100
    path = out_dir / "vortex_axi_breakdown_detail.csv"
    frame.to_csv(path, index=False)
    print(f"wrote {path}")


def main() -> None:
    args = parse_args()
    analysis_run = resolve_path(args.analysis_run)
    report = resolve_path(args.report) if args.report else (
        analysis_run / "top/reports/14_Vortex_axi.mapped.area.rpt"
    )
    estimate_path = resolve_path(args.estimate) if args.estimate else (
        analysis_run / "reports/selective_pnr_estimate.json"
    )
    out_dir = resolve_path(args.out_dir) if args.out_dir else (
        HERE / f"{analysis_run.name}_pnr"
    )

    if not breakdown.report_is_valid(report):
        raise SystemExit(f"area report is missing or incomplete: {report}")
    hdf, dc_total_area = breakdown.load_area_report(report)
    estimate = load_estimate(estimate_path)
    blocks = validate_estimate(
        estimate, dc_total_area, require_converged=args.require_converged
    )
    detail_sums, detail_counts, _ = breakdown.aggregate(hdf)
    components = base_components(detail_sums, hdf)
    corrections = pnr_component_corrections(blocks)
    hybrid_total_area = dc_total_area + sum(corrections.values())

    out_dir.mkdir(parents=True, exist_ok=True)
    write_detail_csv(
        detail_sums,
        detail_counts,
        blocks,
        dc_total_area,
        hybrid_total_area,
        out_dir,
    )
    audit_path = out_dir / "vortex_axi_breakdown_pnr_blocks.csv"
    audit_rows = []
    for block in blocks:
        row = dict(block)
        if (
            block.get("aggregation_mode") == "modeled"
            and block.get("status") == "clean"
        ):
            row["modeled_floorplan_area"] = modeled_floorplan_area(block)
            row["floorplan_correction"] = block_floorplan_correction(block)
        else:
            row["modeled_floorplan_area"] = 0.0
            row["floorplan_correction"] = 0.0
        audit_rows.append(row)
    pd.DataFrame(audit_rows).to_csv(audit_path, index=False)
    print(f"source report: {report}")
    print(f"PnR estimate: {estimate_path}")
    print(
        "hybrid total (DC cell area with routed floorplan replacements): "
        f"{hybrid_total_area:.6f} um^2"
    )
    print(f"wrote {audit_path}")

    for legend_group in breakdown.LEGEND_GROUPS:
        base_summary = summarize_base(components, dc_total_area, legend_group)
        summary = apply_pnr_corrections(
            base_summary, legend_group, corrections
        )
        if not math.isclose(
            sum(summary.values()),
            hybrid_total_area,
            rel_tol=1e-9,
            abs_tol=1e-3,
        ):
            raise SystemExit(
                f"legend group {legend_group.name!r} does not reproduce "
                "the hybrid cell/floorplan area"
            )
        breakdown.write_legend_group_outputs(
            legend_group,
            summary,
            hybrid_total_area,
            out_dir,
            total_label="Hybrid DC-cell / routed-floorplan area",
        )


if __name__ == "__main__":
    main()
