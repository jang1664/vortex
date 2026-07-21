"""Output writers for selective-PnR estimates."""

from __future__ import annotations

import csv
from pathlib import Path

from .aggregate import SelectivePnREstimate


def write_reports(estimate: SelectivePnREstimate, output_dir: str | Path) -> None:
    root = Path(output_dir)
    root.mkdir(parents=True, exist_ok=True)
    (root / "selective_pnr_estimate.json").write_text(
        estimate.model_dump_json(indent=2)
    )
    (root / "selective_pnr_summary.json").write_text(
        estimate.model_dump_json(indent=2)
    )
    (root / "top_summary.json").write_text(
        estimate.model_dump_json(
            indent=2,
            include={
                "estimate_type",
                "top_logical_cell_area",
                "top_physical_cell_area",
                "top_core_area",
                "top_utilization",
                "adjusted_logical_cell_area",
                "adjusted_physical_cell_area",
                "hybrid_core_area",
                "modeled_logical_coverage",
                "modeled_physical_coverage",
            },
        )
    )
    (root / "block_results.json").write_text(
        "[\n"
        + ",\n".join(block.model_dump_json(indent=2) for block in estimate.blocks)
        + "\n]\n"
    )
    _write_csv(estimate, root / "selective_pnr_blocks.csv")
    _write_csv(estimate, root / "block_results.csv")
    (root / "selective_pnr_estimate.md").write_text(_markdown(estimate))
    (root / "selective_pnr_summary.md").write_text(_markdown(estimate))


def _write_csv(estimate: SelectivePnREstimate, path: Path) -> None:
    fields = list(estimate.blocks[0].model_dump()) if estimate.blocks else ["job_id"]
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for block in estimate.blocks:
            row = block.model_dump()
            row["occurrence_paths"] = ";".join(row["occurrence_paths"])
            writer.writerow(row)


def _markdown(estimate: SelectivePnREstimate) -> str:
    lines = [
        "# Selective-PnR Estimate",
        "",
        "This is a selective-PnR estimate, not a final silicon-area result.",
        "",
        "| Metric | Area (um^2) |",
        "|---|---:|",
        f"| Top DC logical cell | {estimate.top_logical_cell_area:.3f} |",
        f"| Top DC physical cell | {estimate.top_physical_cell_area:.3f} |",
        f"| Top DC core | {estimate.top_core_area:.3f} |",
        f"| Adjusted logical cell | {estimate.adjusted_logical_cell_area:.3f} |",
        f"| Adjusted physical cell | {estimate.adjusted_physical_cell_area:.3f} |",
        f"| Hybrid core | {estimate.hybrid_core_area:.3f} |",
        "",
        f"Modeled logical coverage: {estimate.modeled_logical_coverage:.2%}; "
        f"clean modeled physical coverage: {estimate.modeled_physical_coverage:.2%}; "
        f"clean blocks: {estimate.clean_block_count}; failed/unmodeled blocks: "
        f"{estimate.failed_block_count}; diagnostic-only blocks: "
        f"{estimate.diagnostic_block_count}.",
        "",
        "| Block | Instances | Mode | Status | Search | Scale | Gap | DC logical | PnR cell | Growth |",
        "|---|---:|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for block in estimate.blocks:
        pnr = "-" if block.pnr_cell_area is None else f"{block.pnr_cell_area:.3f}"
        growth = "-" if block.growth_factor is None else f"{block.growth_factor:.4f}"
        search = block.search_termination or "-"
        scale = "-" if block.clean_area_scale is None else f"{block.clean_area_scale:.4f}"
        gap = "-" if block.relative_area_gap is None else f"{block.relative_area_gap:.2%}"
        lines.append(
            f"| {block.job_id} | {block.instance_count} | "
            f"{block.aggregation_mode} | {block.status} | {search} | "
            f"{scale} | {gap} | "
            f"{block.dc_logical_area:.3f} | {pnr} | {growth} |"
        )
    lines.append("")
    return "\n".join(lines)
