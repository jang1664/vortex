"""Hybrid top-area estimator for selective block-PnR results."""

from __future__ import annotations

from pathlib import Path
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

from hwexplorer.automation.hierarchical import HierarchicalManifest
from hwexplorer.automation.pnr_result import PnRResult
from hwexplorer.report_db import SynopsysDCAreaDB

from .path_utils import dc_hierarchy_path_candidates


class BlockEstimate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    job_id: str
    template_name: str
    instance_count: int
    status: Literal["clean", "drc_failed", "infrastructure_failed", "not_run"]
    aggregation_mode: Literal["modeled", "diagnostic"] = "modeled"
    hierarchy_logical_area: float
    dc_logical_area: float
    dc_physical_area: float
    estimated_hierarchy_physical_area: float
    pnr_cell_area: Optional[float] = None
    pnr_core_area: Optional[float] = None
    growth_factor: Optional[float] = None
    logical_correction: float = 0.0
    physical_correction: float = 0.0
    core_correction: float = 0.0
    selected_attempt: Optional[int] = None
    occurrence_paths: list[str] = Field(default_factory=list)


class SelectivePnREstimate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    estimate_type: str = "selective-PnR estimate"
    top_logical_cell_area: float
    top_physical_cell_area: float
    top_core_area: float
    top_utilization: float
    adjusted_logical_cell_area: float
    adjusted_physical_cell_area: float
    hybrid_core_area: float
    modeled_logical_area: float
    modeled_logical_coverage: float
    modeled_physical_area: float
    modeled_physical_coverage: float
    clean_block_count: int
    failed_block_count: int
    diagnostic_block_count: int
    blocks: list[BlockEstimate]


def build_estimate(
    top_area_report: str | Path,
    manifest_path: str | Path,
    retry_results: dict[str, list[PnRResult]],
    *,
    diagnostic_job_ids: set[str] | None = None,
) -> SelectivePnREstimate:
    diagnostic_job_ids = diagnostic_job_ids or set()
    top_db = SynopsysDCAreaDB.from_file(str(top_area_report))
    top = top_db.metadata
    top_logical = _required(top, "total_cell_area", top_area_report)
    top_physical = _required(top, "total_physical_cell_area", top_area_report)
    top_core = _required(top, "core_area", top_area_report)
    top_util = _required(top, "utilization_ratio", top_area_report)
    hierarchy = top_db.table(SynopsysDCAreaDB.HIERARCHY_KEY)
    by_path = {
        str(row.full_path): float(row.area)
        for row in hierarchy.itertuples(index=False)
    }

    manifest = HierarchicalManifest.model_validate_json(Path(manifest_path).read_text())
    blocks: list[BlockEstimate] = []
    for job in manifest.synthesis_jobs:
        worker_report = (
            Path(job.run_dir)
            / "reports"
            / f"14_{job.output_name}.mapped.area.rpt"
        )
        worker = SynopsysDCAreaDB.from_file(str(worker_report)).metadata
        dc_logical = _required(worker, "total_cell_area", worker_report)
        dc_physical = _required(worker, "total_physical_cell_area", worker_report)
        paths = list(job.instance_paths)
        occurrence_area = sum(
            _lookup_occurrence_area(by_path, manifest.top_design, path)
            for path in paths
        )
        estimated_physical = occurrence_area * dc_physical / dc_logical

        attempts = retry_results.get(job.job_id, [])
        clean = next((result for result in attempts if result.status == "clean"), None)
        terminal_status = clean.status if clean else (
            attempts[-1].status if attempts else "not_run"
        )
        block = BlockEstimate(
            job_id=job.job_id,
            template_name=job.template_name,
            instance_count=job.instance_count,
            status=terminal_status,
            aggregation_mode=(
                "diagnostic" if job.job_id in diagnostic_job_ids else "modeled"
            ),
            hierarchy_logical_area=occurrence_area,
            dc_logical_area=dc_logical,
            dc_physical_area=dc_physical,
            estimated_hierarchy_physical_area=estimated_physical,
            selected_attempt=clean.attempt if clean else None,
            occurrence_paths=paths,
        )
        if clean is not None:
            assert clean.cell_area is not None
            assert clean.core_area is not None
            growth = clean.cell_area / dc_physical
            scaled_core = clean.core_area * estimated_physical / dc_physical
            block.pnr_cell_area = clean.cell_area
            block.pnr_core_area = clean.core_area
            block.growth_factor = growth
            if block.aggregation_mode == "modeled":
                block.logical_correction = occurrence_area * (growth - 1.0)
                block.physical_correction = estimated_physical * (growth - 1.0)
                block.core_correction = scaled_core - estimated_physical / top_util
        blocks.append(block)

    modeled = sum(
        block.hierarchy_logical_area
        for block in blocks
        if block.aggregation_mode == "modeled"
    )
    modeled_physical = sum(
        block.estimated_hierarchy_physical_area
        for block in blocks
        if block.status == "clean" and block.aggregation_mode == "modeled"
    )
    logical_correction = sum(block.logical_correction for block in blocks)
    physical_correction = sum(block.physical_correction for block in blocks)
    core_correction = sum(block.core_correction for block in blocks)
    modeled_blocks = [block for block in blocks if block.aggregation_mode == "modeled"]
    clean_count = sum(block.status == "clean" for block in modeled_blocks)
    return SelectivePnREstimate(
        top_logical_cell_area=top_logical,
        top_physical_cell_area=top_physical,
        top_core_area=top_core,
        top_utilization=top_util,
        adjusted_logical_cell_area=top_logical + logical_correction,
        adjusted_physical_cell_area=top_physical + physical_correction,
        hybrid_core_area=top_core + core_correction,
        modeled_logical_area=modeled,
        modeled_logical_coverage=modeled / top_logical,
        modeled_physical_area=modeled_physical,
        modeled_physical_coverage=modeled_physical / top_physical,
        clean_block_count=clean_count,
        failed_block_count=len(modeled_blocks) - clean_count,
        diagnostic_block_count=len(blocks) - len(modeled_blocks),
        blocks=blocks,
    )


def _required(metadata: dict, key: str, source: str | Path) -> float:
    value = metadata.get(key)
    if value is None:
        raise ValueError(f"{source} is missing required metric {key}")
    return float(value)


def _lookup_occurrence_area(
    by_path: dict[str, float], top_design: str, instance_path: str
) -> float:
    for candidate in dc_hierarchy_path_candidates(top_design, instance_path):
        if candidate in by_path:
            return by_path[candidate]
    raise ValueError(f"selected occurrence is missing from top area report: {instance_path}")
