#!/usr/bin/env python3
"""Run selective block PnR and build a routing-aware top-area estimate."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import shutil
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
SYNOPSYS_DIR = THIS_DIR.parent
VORTEX_HOME = SYNOPSYS_DIR.parents[2]
HWEXPLORER_HOME = VORTEX_HOME / "third_party" / "hwexplorer"
for path in (str(SYNOPSYS_DIR), str(VORTEX_HOME), str(HWEXPLORER_HOME)):
    if path not in sys.path:
        sys.path.insert(0, path)

from hwexplorer.automation.hierarchical import (  # noqa: E402
    AreaUtilizationPolicy,
    HierarchicalManifest,
    HierarchySelector,
    plan_synthesis_jobs,
    read_design_catalog,
)
from hwexplorer.automation.pnr import (  # noqa: E402
    PnRConfig,
    run_synthesis_job_pnr_search,
)
from hwexplorer.automation.pnr_result import PnRResult, parse_pnr_result  # noqa: E402
from hwexplorer.automation.pnr_search import PnRAreaSearchResult  # noqa: E402
from hwexplorer.report_db import SynopsysDCAreaDB  # noqa: E402
from tools.latency_bench.fpga_bins import load_fpga_bin_aliases  # noqa: E402
from vortex_axi_common import (  # noqa: E402
    _validate_synthesis_result,
    build_vortex_axi_synth_config,
)

from top_analysis.aggregate import build_estimate  # noqa: E402
from top_analysis.config import (  # noqa: E402
    AnalysisConfig,
    CandidatePattern,
    load_analysis_config,
)
from top_analysis.report import write_reports  # noqa: E402
from top_analysis.path_utils import dc_hierarchy_path_candidates  # noqa: E402


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--alias", help="FPGA-bin alias whose config is reused")
    source.add_argument(
        "--config",
        metavar="PATH",
        help=(
            "Vortex config shell script; its filename stem is the default run tag"
        ),
    )
    parser.add_argument("--alias-map")
    parser.add_argument("--run-dir")
    parser.add_argument(
        "--stages", default="top,blocks,pnr,report", help="comma-separated stages"
    )
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--reuse-top")
    parser.add_argument(
        "--candidate-config", default=str(THIS_DIR / "candidates.yaml")
    )
    parser.add_argument("--max-pnr-attempts", type=int)
    parser.add_argument(
        "--initial-area-scale", "--initial-area-margin", type=float
    )
    parser.add_argument(
        "--bracket-factor", "--area-margin-multiplier", type=float
    )
    parser.add_argument("--relative-area-tolerance", type=float)
    parser.add_argument("--min-area-scale", type=float)
    parser.add_argument("--max-area-scale", type=float)
    parser.add_argument("--pnr-job-id")
    parser.add_argument("--report-only", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    config_file, tag = _resolve_config(args)
    analysis_cfg = load_analysis_config(args.candidate_config)
    analysis_cfg = _apply_retry_overrides(analysis_cfg, args)
    stages = ["report"] if args.report_only else args.stages.split(",")
    invalid = set(stages) - {"top", "blocks", "pnr", "report"}
    if invalid:
        raise SystemExit("unsupported stages: " + ", ".join(sorted(invalid)))

    run_dir = Path(args.run_dir or (
        VORTEX_HOME / "build/hw/syn/synopsys/top_analysis" / f"Vortex_axi_{tag}"
    )).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    top_dir = Path(args.reuse_top).resolve() if args.reuse_top else run_dir / "top"
    resolved = {
        "config_file": str(config_file),
        "run_tag": tag,
        "run_dir": str(run_dir),
        "top_dir": str(top_dir),
        "stages": stages,
        "pnr_search": analysis_cfg.pnr.search_policy().model_dump(mode="json"),
        "candidate_config": analysis_cfg.model_dump(mode="json"),
    }
    (run_dir / "resolved_config.json").write_text(json.dumps(resolved, indent=2))

    top_cfg = None
    if any(stage in stages for stage in ("top", "blocks")):
        top_cfg, _, _, _ = build_vortex_axi_synth_config(
            config_file,
            tag,
            result_root=run_dir,
            syn_dir="top",
            generate_design_catalog=True,
            skip_write_icc2_files=True,
            rerun=not args.resume,
        )

    if "top" in stages and not args.reuse_top:
        assert top_cfg is not None
        ret = top_cfg.run()
        if ret:
            return ret
        _validate_top(top_dir)
    elif any(stage in stages for stage in ("blocks", "pnr", "report")):
        _validate_top(top_dir)

    if "blocks" in stages:
        assert top_cfg is not None
        selectors = _plan_candidates(top_dir, analysis_cfg, run_dir)
        block_cfg = top_cfg.model_copy(
            deep=True,
            update={
                "design_dir": str(run_dir),
                "syn_dir": "blocks",
                "synthesis_mode": "submodule",
                "hierarchy_selectors": selectors,
                "synthesis_constraint_profiles": analysis_cfg.block_constraints,
                "output_profile": "icc2_handoff",
                "physical_variants": [],
                "generate_design_catalog": False,
                "existing_design_catalog_path": str(
                    top_dir / "results/design_catalog.tsv"
                ),
                "elaborated_ddc_path": str(
                    top_dir / "results/Vortex_axi.elab.ddc"
                ),
                "elaboration_top_name": "Vortex_axi",
                "skip_write_icc2_files": False,
                "rerun": not args.resume,
            },
        )
        ret = block_cfg.run()
        if ret:
            return ret

    manifest_path = run_dir / "blocks/hierarchical_manifest.json"
    if "pnr" in stages:
        if not manifest_path.is_file():
            raise SystemExit(f"block synthesis manifest is missing: {manifest_path}")
        ret = _run_pnr_attempts(
            manifest_path,
            analysis_cfg,
            run_dir,
            resume=args.resume,
            only_job_id=args.pnr_job_id,
        )
        if ret:
            return ret

    if "report" in stages:
        retry_results = _load_retry_results(run_dir / "pnr_results.json")
        search_results = _load_search_results(run_dir / "pnr_search_results.json")
        candidate_plan_path = run_dir / "candidate_plan.json"
        candidate_plan = (
            json.loads(candidate_plan_path.read_text())
            if candidate_plan_path.is_file()
            else {}
        )
        estimate = build_estimate(
            top_dir / "reports/14_Vortex_axi.mapped.area.rpt",
            manifest_path,
            retry_results,
            diagnostic_job_ids=set(candidate_plan.get("diagnostic_job_ids", [])),
            search_results=search_results,
        )
        write_reports(estimate, run_dir / "reports")
        shutil.copy2(
            run_dir / "resolved_config.json", run_dir / "reports/resolved_config.json"
        )
        print(f"# selective-PnR estimate: {run_dir / 'reports/selective_pnr_estimate.md'}")
    return 0


def _resolve_config(args: argparse.Namespace) -> tuple[Path, str]:
    if args.config:
        path = Path(args.config).expanduser().resolve()
        tag = path.stem
    else:
        aliases = load_fpga_bin_aliases(args.alias_map)
        selected = aliases.get(args.alias)
        if selected is None or not selected.configs:
            raise SystemExit(f"unknown or unconfigured FPGA alias: {args.alias}")
        path = (VORTEX_HOME / selected.configs).resolve()
        tag = args.alias
    if not path.is_file():
        raise SystemExit(f"Vortex config does not exist: {path}")
    return path, tag


def _apply_retry_overrides(
    config: AnalysisConfig, args: argparse.Namespace
) -> AnalysisConfig:
    updates = {}
    for cli_name, field in (
        ("max_pnr_attempts", "max_attempts"),
        ("initial_area_scale", "initial_area_scale"),
        ("bracket_factor", "bracket_factor"),
        ("relative_area_tolerance", "relative_area_tolerance"),
        ("min_area_scale", "min_area_scale"),
        ("max_area_scale", "max_area_scale"),
    ):
        value = getattr(args, cli_name)
        if value is not None:
            updates[field] = value
    if not updates:
        return config
    return config.model_copy(update={"pnr": config.pnr.model_copy(update=updates)})


def _validate_top(top_dir: Path) -> None:
    _validate_synthesis_result(top_dir, "Vortex_axi")
    required = [
        top_dir / "results/design_catalog.tsv",
        top_dir / "results/Vortex_axi.elab.ddc",
    ]
    missing = [str(path) for path in required if not path.is_file() or not path.stat().st_size]
    if missing:
        raise SystemExit("top analysis artifacts are missing/empty:\n  " + "\n  ".join(missing))
    db = SynopsysDCAreaDB.from_file(
        str(top_dir / "reports/14_Vortex_axi.mapped.area.rpt")
    )
    for metric in ("total_cell_area", "total_physical_cell_area", "core_area"):
        if db.metadata.get(metric) is None:
            raise SystemExit(f"top DC area report is missing {metric}")


def _plan_candidates(
    top_dir: Path, config: AnalysisConfig, run_dir: Path
) -> list[HierarchySelector]:
    catalog = read_design_catalog(top_dir / "results/design_catalog.tsv")
    modeled_designs: set[str] = set()
    diagnostic_designs: set[str] = set()
    unmatched: list[dict] = []
    diagnostic_designs: set[str] = set()
    for kind, rules in (
        ("module", config.include.modules),
        ("design", config.include.designs),
        ("instance", config.include.instances),
    ):
        for rule in rules:
            matches = [design for design in catalog if _candidate_matches(kind, rule, design)]
            if not matches:
                unmatched.append({"kind": kind, **rule.model_dump()})
                if rule.required:
                    raise ValueError(f"required candidate matched nothing: {kind}:{rule.pattern}")
                continue
            for design in matches:
                if rule.diagnostic_only:
                    if design.design_name not in modeled_designs:
                        diagnostic_designs.add(design.design_name)
                else:
                    modeled_designs.add(design.design_name)
                    diagnostic_designs.discard(design.design_name)

    selected_designs = {
        name for name in modeled_designs | diagnostic_designs
        if not _excluded(next(d for d in catalog if d.design_name == name), config)
    }
    diagnostic_designs &= selected_designs
    initial_selectors = [
        HierarchySelector(kind="design", value=name) for name in sorted(selected_designs)
    ]
    if not initial_selectors:
        raise ValueError("candidate configuration selected no elaborated designs")
    jobs = plan_synthesis_jobs(
        catalog, initial_selectors, "candidate-preflight", "icc2_handoff"
    )

    top_db = SynopsysDCAreaDB.from_file(
        str(top_dir / "reports/14_Vortex_axi.mapped.area.rpt")
    )
    by_path = {
        str(row.full_path): float(row.area)
        for row in top_db.table(SynopsysDCAreaDB.HIERARCHY_KEY).itertuples(index=False)
    }
    kept = []
    dropped = []
    for job in jobs:
        area = sum(_path_area(by_path, path) for path in job.instance_paths)
        record = {
            "job_id": job.job_id,
            "template_name": job.template_name,
            "area": area,
            "diagnostic_only": job.design_name in diagnostic_designs,
        }
        if area < config.minimum_total_area_um2:
            dropped.append(record)
        else:
            kept.append((job, record))
    _validate_nonoverlap(
        [
            path
            for job, record in kept
            if not record["diagnostic_only"]
            for path in job.instance_paths
        ],
        config.allow_nested,
    )
    selectors = [
        HierarchySelector(kind="design", value=job.design_name) for job, _ in kept
    ]
    if not selectors:
        raise ValueError("all selected candidates were below minimum_total_area_um2")
    planning = {
        "unmatched": unmatched,
        "diagnostic_designs": sorted(diagnostic_designs),
        "diagnostic_job_ids": [
            job.job_id for job, record in kept if record["diagnostic_only"]
        ],
        "selected": [record for _, record in kept],
        "dropped_below_area": dropped,
        "selectors": [selector.model_dump() for selector in selectors],
    }
    (run_dir / "candidate_plan.json").write_text(json.dumps(planning, indent=2))
    return selectors


def _candidate_matches(kind: str, rule: CandidatePattern, design) -> bool:
    if kind == "module":
        return _matches(design.template_name, rule.pattern)
    if kind == "design":
        return _matches(design.design_name, rule.pattern)
    return any(_matches(path, rule.pattern) for path in design.instance_paths)


def _excluded(design, config: AnalysisConfig) -> bool:
    return (
        any(_matches(design.template_name, pattern) for pattern in config.exclude.modules)
        or any(_matches(design.design_name, pattern) for pattern in config.exclude.designs)
        or any(
            _matches(path, pattern)
            for path in design.instance_paths
            for pattern in config.exclude.instances
        )
    )


def _matches(value: str, pattern: str) -> bool:
    return value == pattern or fnmatch.fnmatchcase(value, pattern)


def _path_area(by_path: dict[str, float], path: str) -> float:
    for candidate in dc_hierarchy_path_candidates("Vortex_axi", path):
        if candidate in by_path:
            return by_path[candidate]
    raise ValueError(f"catalog occurrence is missing from top area report: {path}")


def _validate_nonoverlap(paths: list[str], allow_nested: bool) -> None:
    if allow_nested:
        return
    normalized = sorted({path.strip("/") for path in paths})
    for index, parent in enumerate(normalized):
        for child in normalized[index + 1 :]:
            if child.startswith(parent + "/"):
                raise ValueError(f"nested candidates would double count area: {parent} and {child}")


def _run_pnr_attempts(
    manifest_path: Path,
    config: AnalysisConfig,
    run_dir: Path,
    *,
    resume: bool,
    only_job_id: str | None,
) -> int:
    manifest = HierarchicalManifest.model_validate_json(manifest_path.read_text())
    results = _load_retry_results(run_dir / "pnr_results.json")
    search_results = _load_search_results(run_dir / "pnr_search_results.json")
    for job in manifest.synthesis_jobs:
        if only_job_id and job.job_id != only_job_id:
            continue
        existing = results.get(job.job_id, []) if resume else []
        if resume and existing:
            # Re-evaluate preserved attempts from their stable reports.  This
            # lets parser fixes or relaxed DRC policy take effect without
            # rerunning ICC2.
            refreshed = []
            for previous in existing:
                area_scale = _result_area_scale(previous)
                if area_scale is None:
                    continue
                result = parse_pnr_result(
                    previous.run_dir,
                    return_code=previous.return_code,
                    job_id=previous.job_id or job.job_id,
                    design_name=previous.design_name,
                    attempt=previous.attempt,
                    area_scale=area_scale,
                    die_width=previous.die_width,
                    die_height=previous.die_height,
                    max_routing_drc_errors=config.pnr.max_routing_drc_errors,
                )
                result.write(Path(previous.run_dir) / "pnr_result.json")
                refreshed.append(result)
            existing = refreshed
            results[job.job_id] = existing
            _write_retry_results(run_dir / "pnr_results.json", results)
        results[job.job_id] = existing

        def checkpoint(attempts: list[PnRResult]) -> None:
            results[job.job_id] = attempts
            _write_retry_results(run_dir / "pnr_results.json", results)

        search = run_synthesis_job_pnr_search(
            manifest,
            job,
            config.pnr.search_policy(),
            AreaUtilizationPolicy(
                target_utilization=config.pnr.target_utilization,
                aspect_ratio=config.pnr.aspect_ratio,
                boundary_margin=config.pnr.boundary_margin,
                width_grid=config.pnr.width_grid,
                height_grid=config.pnr.height_grid,
            ),
            PnRConfig(
                tech="lpp",
                validate_routing_drc=True,
                max_routing_drc_errors=config.pnr.max_routing_drc_errors,
                rerun=not resume,
                backup=False,
                new=True,
            ),
            existing_attempts=existing,
            checkpoint=checkpoint,
        )
        results[job.job_id] = search.attempts
        search_results[job.job_id] = search
        _write_retry_results(run_dir / "pnr_results.json", results)
        _write_search_results(run_dir / "pnr_search_results.json", search_results)
        search_path = Path(job.run_dir) / "pnr_search_result.json"
        search_path.parent.mkdir(parents=True, exist_ok=True)
        search.write(search_path)
        if search.termination == "infrastructure_failed":
            failed = next(
                result
                for result in reversed(search.attempts)
                if result.status == "infrastructure_failed"
            )
            return failed.return_code or 2
        # A bounded search without a clean result is a modeled block failure,
        # not an orchestration/infrastructure failure.
    return 0


def _result_area_scale(result: PnRResult) -> float | None:
    if result.area_scale is not None:
        return result.area_scale
    match = re.search(r"(?:margin|scale)_([0-9]+(?:\.[0-9]+)?)", result.run_dir)
    return float(match.group(1)) if match else None


def _load_retry_results(path: Path) -> dict[str, list[PnRResult]]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text())
    return {
        job_id: [PnRResult.model_validate(item) for item in attempts]
        for job_id, attempts in data.items()
    }


def _write_retry_results(path: Path, results: dict[str, list[PnRResult]]) -> None:
    payload = {
        job_id: [result.model_dump(mode="json") for result in attempts]
        for job_id, attempts in results.items()
    }
    path.write_text(json.dumps(payload, indent=2))


def _load_search_results(path: Path) -> dict[str, PnRAreaSearchResult]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text())
    return {
        job_id: PnRAreaSearchResult.model_validate(result)
        for job_id, result in data.items()
    }


def _write_search_results(
    path: Path, results: dict[str, PnRAreaSearchResult]
) -> None:
    payload = {
        job_id: result.model_dump(mode="json") for job_id, result in results.items()
    }
    path.write_text(json.dumps(payload, indent=2))


if __name__ == "__main__":
    raise SystemExit(main())
