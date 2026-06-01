from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from .suite import BenchCase, BenchDefaults, BenchSuite, find_repo_root, load_suite, sanitize_id, suite_to_expanded_yaml


@dataclass(frozen=True)
class GenerateSuitesOptions:
    suite: Path
    out_dir: Path
    overwrite: bool = False
    repo_root: Path | None = None


def _mapping_value(mapping: Any, key: str) -> str:
    if not key or not isinstance(mapping, dict):
        return ""
    value = mapping.get(key)
    return str(value) if value is not None else ""


def resolve_case_fpga_bin(suite: BenchSuite, case: BenchCase) -> str:
    if case.fpga_bin:
        return case.fpga_bin

    spec = suite.fpga_bins or {}
    by_app = spec.get("by_app") or {}
    by_backend = spec.get("by_backend") or {}
    by_kind = spec.get("by_kind") or spec.get("by_kernel") or spec.get("kernels") or {}

    fpga_bin = _mapping_value(by_app, case.app)
    if fpga_bin:
        return fpga_bin
    fpga_bin = _mapping_value(by_backend, case.backend)
    if fpga_bin:
        return fpga_bin
    fpga_bin = _mapping_value(by_kind, case.kind)
    if fpga_bin:
        return fpga_bin
    fpga_bin = str(spec.get("default", "") or suite.defaults.fpga_bin)
    if fpga_bin:
        return fpga_bin
    raise ValueError(
        f"no fpga_bin mapping for case {case.case_id!r}; "
        "set case.fpga_bin, fpga_bins.default, or defaults.fpga_bin"
    )


def _case_without_fpga_bin(case: BenchCase) -> BenchCase:
    return BenchCase(**{**case.__dict__, "fpga_bin": ""})


def _group_name(base_name: str, app: str, fpga_bin: str) -> str:
    return sanitize_id(f"{base_name}__{app}__{fpga_bin}")


def _run_command(suite_path: Path, out_dir: Path) -> str:
    return " ".join([
        "python",
        "-m",
        "tools.latency_bench",
        "run",
        "--suite",
        shlex.quote(str(suite_path)),
        "--out",
        shlex.quote(str(out_dir)),
    ])


def generate_suites(options: GenerateSuitesOptions) -> dict[str, Any]:
    repo_root = options.repo_root or find_repo_root()
    source_suite = load_suite(options.suite, repo_root=repo_root)
    out_dir = options.out_dir.expanduser().resolve()

    groups: dict[tuple[str, str], list[BenchCase]] = {}
    for case in source_suite.cases:
        fpga_bin = resolve_case_fpga_bin(source_suite, case)
        groups.setdefault((case.app, fpga_bin), []).append(case)

    generated_specs: list[tuple[Path, BenchSuite, str, str]] = []
    for app, fpga_bin in sorted(groups):
        name = _group_name(source_suite.name, app, fpga_bin)
        generated_suite = BenchSuite(
            name=name,
            defaults=BenchDefaults(**{**source_suite.defaults.__dict__, "app": app, "fpga_bin": fpga_bin}),
            cases=[_case_without_fpga_bin(case) for case in groups[(app, fpga_bin)]],
        )
        generated_specs.append((out_dir / f"{name}.yaml", generated_suite, app, fpga_bin))

    index_path = out_dir / "index.yaml"
    targets = [index_path, *(path for path, _suite, _app, _fpga_bin in generated_specs)]
    existing = [path for path in targets if path.exists()]
    if existing and not options.overwrite:
        formatted = ", ".join(str(path) for path in existing)
        raise FileExistsError(f"generated suite output already exists; use --overwrite: {formatted}")

    out_dir.mkdir(parents=True, exist_ok=True)
    index: dict[str, Any] = {
        "base_suite": str(options.suite.expanduser().resolve()),
        "output_dir": str(out_dir),
        "generated": [],
    }
    for suite_path, generated_suite, app, fpga_bin in generated_specs:
        with suite_path.open("w") as fp:
            yaml.safe_dump(suite_to_expanded_yaml(generated_suite), fp, sort_keys=False)
        kinds = sorted({case.kind for case in generated_suite.cases if case.kind})
        backends = sorted({case.backend for case in generated_suite.cases if case.backend})
        index["generated"].append({
            "suite": str(suite_path),
            "name": generated_suite.name,
            "app": app,
            "fpga_bin": fpga_bin,
            "kinds": kinds,
            "backends": backends,
            "case_count": len(generated_suite.cases),
            "run_command": _run_command(suite_path, out_dir / generated_suite.name),
        })

    with index_path.open("w") as fp:
        yaml.safe_dump(index, fp, sort_keys=False)
    return index
