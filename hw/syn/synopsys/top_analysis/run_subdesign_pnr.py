#!/usr/bin/env python3
"""Synthesize selected C3/C4 subdesigns, then run their PnR jobs in a batch.

This flow reuses a completed top-level elaboration catalog/DDC when available.
Without a seed it runs catalog-only top elaboration once, then launches the
selected workers. All selected synthesis workers finish before the first PnR
search is launched.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path
from typing import Any

import yaml

THIS_DIR = Path(__file__).resolve().parent
SYNOPSYS_DIR = THIS_DIR.parent
VORTEX_HOME = SYNOPSYS_DIR.parents[2]
HWEXPLORER_HOME = VORTEX_HOME / "third_party" / "hwexplorer"
for path in (SYNOPSYS_DIR, VORTEX_HOME, HWEXPLORER_HOME):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from hwexplorer.automation.hierarchical import (  # noqa: E402
    ElaboratedDesign,
    HierarchySelector,
    read_design_catalog,
)
from hwexplorer.automation.syn import SynthConfig, _run_single_synthesis  # noqa: E402
from tools.latency_bench.fpga_bins import load_fpga_bin_aliases  # noqa: E402
from vortex_axi_common import build_vortex_axi_synth_config  # noqa: E402

from top_analysis.config import load_analysis_config  # noqa: E402
from top_analysis.run import _run_pnr_attempts  # noqa: E402


DEFAULT_MATCH_CONFIG = THIS_DIR / "subdesign_candidates.yaml"
DEFAULT_ANALYSIS_CONFIG = THIS_DIR / "candidates.yaml"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--alias", help="FPGA alias, such as C3 or C4")
    source.add_argument("--config", metavar="PATH", help="Vortex config shell script")
    parser.add_argument("--alias-map", help="FPGA alias map path")
    parser.add_argument(
        "--family",
        choices=("C3", "C4"),
        help="Override family inference; extend this choice when adding C1/C2",
    )
    parser.add_argument(
        "--seed-run-dir",
        help=(
            "Existing top result containing results/design_catalog.tsv and "
            "results/Vortex_axi.elab.ddc"
        ),
    )
    parser.add_argument("--run-dir", help="Output directory for subdesign results")
    parser.add_argument("--match-config", default=str(DEFAULT_MATCH_CONFIG))
    parser.add_argument("--analysis-config", default=str(DEFAULT_ANALYSIS_CONFIG))
    parser.add_argument("--stages", default="synth,pnr", help="synth,pnr or pnr")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--pnr-job-id")
    parser.add_argument("--max-pnr-attempts", type=int)
    parser.add_argument("--initial-area-scale", type=float)
    parser.add_argument("--bracket-factor", type=float)
    parser.add_argument("--relative-area-tolerance", type=float)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    stages = _parse_stages(args.stages)
    config_file, tag = _resolve_config(args)
    match_config = _load_match_config(args.match_config)
    family = _resolve_family(match_config, args.family, args.alias, config_file)
    run_dir = Path(
        args.run_dir
        or VORTEX_HOME
        / "build/hw/syn/synopsys/top_analysis"
        / f"Vortex_axi_subdesign_{tag}"
    ).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)

    seed = None
    plan: dict[str, Any] = {
        "config_file": str(config_file),
        "run_tag": tag,
        "family": family,
        "run_dir": str(run_dir),
        "stages": stages,
        "match_config": str(Path(args.match_config).resolve()),
        "analysis_config": str(Path(args.analysis_config).resolve()),
    }
    if "synth" in stages or args.dry_run:
        if args.seed_run_dir:
            seed = _resolve_seed_run_dir(args.seed_run_dir, config_file, tag, run_dir)
        else:
            try:
                seed = _resolve_seed_run_dir(None, config_file, tag, run_dir)
            except SystemExit:
                if args.dry_run:
                    raise SystemExit(
                        "--dry-run needs --seed-run-dir because it cannot run top elaboration"
                    )
                print("# no reusable seed found; running catalog-only top elaboration")
                seed = _run_catalog_elaboration(config_file, tag, run_dir, rerun=not args.resume)
        catalog = read_design_catalog(seed["catalog"])
        selectors, matches = _select_targets(catalog, match_config, family)
        plan.update(
            {
                "seed_run_dir": str(seed["root"]),
                "catalog": str(seed["catalog"]),
                "elaborated_ddc": str(seed["ddc"]),
                "selectors": [item.model_dump() for item in selectors],
                "matches": matches,
            }
        )
    else:
        selectors = []

    (run_dir / "resolved_config.json").write_text(json.dumps(plan, indent=2))
    (run_dir / "subdesign_plan.json").write_text(json.dumps(plan, indent=2))
    if args.dry_run:
        _print_plan(plan)
        return 0

    analysis_config = load_analysis_config(args.analysis_config)
    analysis_config = _apply_pnr_overrides(analysis_config, args)

    if "synth" in stages:
        assert seed is not None
        synth_cfg = _build_subdesign_synth_config(
            config_file,
            tag,
            run_dir,
            seed,
            selectors,
            analysis_config,
            rerun=not args.resume,
        )
        print(f"# synthesizing {len(selectors)} selected subdesign selectors")
        ret = synth_cfg.run()
        if ret:
            return ret

    manifest_path = run_dir / "blocks/hierarchical_manifest.json"
    if "pnr" in stages:
        if not manifest_path.is_file():
            raise SystemExit(
                f"subdesign synthesis manifest is missing: {manifest_path}; "
                "run with --stages synth,pnr first"
            )
        print("# all selected synthesis workers completed; starting PnR")
        return _run_pnr_attempts(
            manifest_path,
            analysis_config,
            run_dir,
            resume=args.resume,
            only_job_id=args.pnr_job_id,
        )
    return 0


def _parse_stages(value: str) -> list[str]:
    stages = [item.strip() for item in value.split(",") if item.strip()]
    invalid = set(stages) - {"synth", "pnr"}
    if invalid or not stages:
        raise SystemExit("stages must be a comma-separated subset of synth,pnr")
    if "synth" in stages and "pnr" in stages:
        if stages.index("pnr") < stages.index("synth"):
            raise SystemExit("synthesis must precede PnR; use --stages synth,pnr")
    return stages


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


def _load_match_config(path: str | Path) -> dict[str, Any]:
    data = yaml.safe_load(Path(path).read_text()) or {}
    if not isinstance(data.get("common_targets"), list):
        raise SystemExit(f"match config has no common_targets list: {path}")
    families = data.get("families")
    if not isinstance(families, dict) or not families:
        raise SystemExit(f"match config has no families: {path}")
    return data


def _resolve_family(
    config: dict[str, Any], requested: str | None, alias: str | None, config_file: Path
) -> str:
    families = config["families"]
    if requested:
        if requested not in families:
            raise SystemExit(f"family {requested} is not defined in match config")
        return requested
    value = alias or config_file.name
    matches = []
    for family, spec in families.items():
        patterns = spec.get("alias_patterns" if alias else "config_patterns", [])
        if any(fnmatch.fnmatchcase(value, pattern) for pattern in patterns):
            matches.append(family)
    if len(matches) != 1:
        raise SystemExit(
            f"cannot infer C3/C4 family for {value!r}; use --family C3 or --family C4"
        )
    return matches[0]


def _resolve_seed_run_dir(
    explicit: str | None, config_file: Path, tag: str, output_dir: Path
) -> dict[str, Path]:
    candidates: list[Path] = []
    if explicit:
        supplied = Path(explicit).expanduser().resolve()
        candidates.extend((supplied, supplied / "top", supplied / "syn_topo.lpp"))
    else:
        candidates.extend(
            [
                VORTEX_HOME / "build/hw/syn/synopsys/top_analysis" / f"Vortex_axi_{tag}" / "top",
                VORTEX_HOME
                / "build/hw/syn/synopsys/top_analysis"
                / f"Vortex_axi_{config_file.stem}"
                / "top",
                VORTEX_HOME / "build/hw/syn/synopsys" / f"Vortex_axi_{tag}" / "syn_topo.lpp",
            ]
        )
    for root in candidates:
        catalog = root / "results/design_catalog.tsv"
        ddc = root / "results/Vortex_axi.elab.ddc"
        if catalog.is_file() and ddc.is_file() and catalog.stat().st_size and ddc.stat().st_size:
            if root.resolve() == output_dir.resolve():
                continue
            return {"root": root.resolve(), "catalog": catalog, "ddc": ddc}
    rendered = "\n  ".join(str(path) for path in candidates)
    raise SystemExit(
        "reusable top catalog/DDC not found. Pass --seed-run-dir pointing to a "
        "completed top result; checked:\n  " + rendered
    )


def _select_targets(
    catalog: list[ElaboratedDesign], config: dict[str, Any], family: str
) -> tuple[list[HierarchySelector], list[dict[str, Any]]]:
    targets = [*config["common_targets"], *config["families"][family].get("targets", [])]
    selected: dict[str, set[str]] = {}
    matches: list[dict[str, Any]] = []
    for target in targets:
        name = target.get("name", "unnamed")
        matched = [design for design in catalog if _target_matches(design, target)]
        if not matched:
            if target.get("required", False):
                raise SystemExit(f"required subdesign target matched nothing: {name}")
            matches.append({"name": name, "matched": 0, "designs": []})
            continue
        for design in matched:
            selected.setdefault(design.design_name, set()).add(name)
        matches.append(
            {
                "name": name,
                "matched": len(matched),
                "designs": [design.design_name for design in matched],
            }
        )
    if not selected:
        raise SystemExit(f"family {family} selected no subdesigns")
    selectors = [
        HierarchySelector(kind="design", value=design_name)
        for design_name in sorted(selected)
    ]
    for item in matches:
        item["selected_by"] = {
            design_name: sorted(names)
            for design_name, names in selected.items()
            if item["name"] in names
        }
    return selectors, matches


def _target_matches(design: ElaboratedDesign, target: dict[str, Any]) -> bool:
    for field, value in (
        ("module_patterns", design.template_name),
        ("design_patterns", design.design_name),
    ):
        patterns = target.get(field, [])
        if patterns and not any(fnmatch.fnmatchcase(value, pattern) for pattern in patterns):
            return False
    instance_patterns = target.get("instance_patterns", [])
    if instance_patterns and not any(
        _path_matches(path, pattern)
        for path in design.instance_paths
        for pattern in instance_patterns
    ):
        return False
    return True


def _path_matches(path: str, pattern: str) -> bool:
    """Match hierarchy globs while allowing ** to represent zero levels."""
    return fnmatch.fnmatchcase(path, pattern) or fnmatch.fnmatchcase(
        path, pattern.replace("/**/", "/")
    )


def _build_subdesign_synth_config(
    config_file: Path,
    tag: str,
    run_dir: Path,
    seed: dict[str, Path],
    selectors: list[HierarchySelector],
    analysis_config,
    *,
    rerun: bool,
) -> SynthConfig:
    base, _, _, _ = build_vortex_axi_synth_config(
        config_file,
        tag,
        result_root=run_dir,
        syn_dir="blocks",
        generate_design_catalog=False,
        skip_write_icc2_files=False,
        rerun=rerun,
    )
    return base.model_copy(
        deep=True,
        update={
            "synthesis_mode": "submodule",
            "hierarchy_selectors": selectors,
            "synthesis_constraint_profiles": analysis_config.block_constraints,
            "output_profile": "icc2_handoff",
            "physical_variants": [],
            "generate_design_catalog": False,
            "existing_design_catalog_path": str(seed["catalog"]),
            "elaborated_ddc_path": str(seed["ddc"]),
            "elaboration_top_name": "Vortex_axi",
            "target_design_name": "",
            "constraint_context": "fast-subdesign-pnr",
            "skip_write_icc2_files": False,
        },
    )


def _run_catalog_elaboration(
    config_file: Path, tag: str, run_dir: Path, *, rerun: bool
) -> dict[str, Path]:
    """Create a reusable catalog/DDC without top-level compile or PnR."""
    base, _, _, _ = build_vortex_axi_synth_config(
        config_file,
        tag,
        result_root=run_dir,
        syn_dir="top",
        generate_design_catalog=True,
        skip_write_icc2_files=True,
        rerun=rerun,
    )
    catalog_cfg = base.model_copy(
        deep=True,
        update={
            "synthesis_mode": "catalog",
            "output_profile": "reports_only",
            "generate_design_catalog": True,
            "skip_write_icc2_files": True,
            "target_design_name": "",
            "hierarchy_selectors": [],
        },
    )
    ret = _run_single_synthesis(catalog_cfg)
    if ret:
        raise SystemExit(f"catalog-only top elaboration failed with status {ret}")
    root = run_dir / "top"
    catalog = root / "results/design_catalog.tsv"
    ddc = root / "results/Vortex_axi.elab.ddc"
    if not catalog.is_file() or not ddc.is_file():
        raise SystemExit(
            "catalog-only top elaboration completed without the expected "
            f"catalog/DDC artifacts under {root / 'results'}"
        )
    return {"root": root.resolve(), "catalog": catalog, "ddc": ddc}


def _apply_pnr_overrides(config, args):
    updates = {
        field: value
        for field, value in (
            ("max_attempts", args.max_pnr_attempts),
            ("initial_area_scale", args.initial_area_scale),
            ("bracket_factor", args.bracket_factor),
            ("relative_area_tolerance", args.relative_area_tolerance),
        )
        if value is not None
    }
    if not updates:
        return config
    return config.model_copy(update={"pnr": config.pnr.model_copy(update=updates)})


def _print_plan(plan: dict[str, Any]) -> None:
    print(f"# family: {plan['family']}")
    print(f"# seed: {plan.get('seed_run_dir', '<not resolved>')}")
    print(f"# selectors: {len(plan.get('selectors', []))}")
    for selector in plan.get("selectors", []):
        print(f"  {selector['kind']}:{selector['value']}")


if __name__ == "__main__":
    raise SystemExit(main())
