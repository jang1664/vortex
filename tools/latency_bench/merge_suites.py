from __future__ import annotations

import glob
import json
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from .generate_suites import resolve_case_fpga_bin
from .suite import BenchCase, BenchDefaults, BenchSuite, find_repo_root, load_suite, sanitize_id, suite_to_expanded_yaml


@dataclass(frozen=True)
class MergeSuitesOptions:
    suite_globs: tuple[str, ...]
    out: Path
    name: str = ""
    group_by_fpga_bin: bool = False
    overwrite: bool = False
    repo_root: Path | None = None


def _expand_suite_globs(patterns: tuple[str, ...]) -> list[Path]:
    paths: dict[Path, None] = {}
    for pattern in patterns:
        expanded = glob.glob(str(Path(pattern).expanduser()), recursive=True)
        for match in expanded:
            path = Path(match).expanduser().resolve()
            if path.name == "index.yaml":
                continue
            if path.suffix not in (".yaml", ".yml"):
                continue
            paths[path] = None
    out = sorted(paths)
    if not out:
        raise ValueError("no suite YAML files matched")
    return out


def _check_compatible_defaults(base: BenchDefaults, suite: BenchSuite, path: Path) -> None:
    fields = ("target", "platform", "xrt_device_index", "blackbox_args", "blackbox_timeout")
    for field in fields:
        if getattr(base, field) != getattr(suite.defaults, field):
            raise ValueError(
                f"incompatible suite default {field!r} in {path}: "
                f"{getattr(suite.defaults, field)!r} != {getattr(base, field)!r}"
            )


def _case_for_merge(case: BenchCase, *, case_id: str, source_path: Path) -> BenchCase:
    return BenchCase(**{
        **case.__dict__,
        "case_id": case_id,
        "source": f"merge:{source_path.name}:{case.case_id}",
        "fpga_bin": "",
    })


def _unique_case_id(case_id: str, used: set[str]) -> str:
    base = sanitize_id(case_id)
    out = base
    suffix = 2
    while out in used:
        out = f"{base}_{suffix}"
        suffix += 1
    used.add(out)
    return out


def _logical_case_key(fpga_bin: str, case: BenchCase) -> tuple[str, str]:
    payload = {
        key: value
        for key, value in case.__dict__.items()
        if key not in {"source", "fpga_bin"}
    }
    return fpga_bin, json.dumps(payload, sort_keys=True, default=str)


def _merged_suite(
    *,
    name: str,
    defaults: BenchDefaults,
    fpga_bin: str,
    cases: list[BenchCase],
) -> BenchSuite:
    return BenchSuite(
        name=sanitize_id(name),
        defaults=BenchDefaults(**{**defaults.__dict__, "app": cases[0].app if len({c.app for c in cases}) == 1 else defaults.app, "fpga_bin": fpga_bin}),
        cases=cases,
    )


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


def _write_suite(path: Path, suite: BenchSuite, *, overwrite: bool) -> None:
    if path.exists() and not overwrite:
        raise FileExistsError(f"merged suite output already exists; use --overwrite: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fp:
        yaml.safe_dump(suite_to_expanded_yaml(suite), fp, sort_keys=False)


def merge_suites(options: MergeSuitesOptions) -> dict[str, Any]:
    if not options.suite_globs:
        raise ValueError("at least one --suite-glob is required")

    repo_root = options.repo_root or find_repo_root()
    suite_paths = _expand_suite_globs(options.suite_globs)
    loaded = [(path, load_suite(path, repo_root=repo_root)) for path in suite_paths]
    base_defaults = loaded[0][1].defaults
    for path, suite in loaded[1:]:
        _check_compatible_defaults(base_defaults, suite, path)

    groups: dict[str, list[tuple[Path, BenchCase]]] = {}
    seen_logical_cases: set[tuple[str, str]] = set()
    logical_duplicate_count = 0
    execution_keys: set[tuple[str, str]] = set()
    for path, suite in loaded:
        for case in suite.cases:
            fpga_bin = resolve_case_fpga_bin(suite, case)
            logical_key = _logical_case_key(fpga_bin, case)
            if logical_key in seen_logical_cases:
                logical_duplicate_count += 1
                continue
            seen_logical_cases.add(logical_key)
            execution_keys.add((fpga_bin, case.exec_key))
            groups.setdefault(fpga_bin, []).append((path, case))

    base_name = sanitize_id(options.name or options.out.stem)
    if not options.group_by_fpga_bin:
        if len(groups) != 1:
            raise ValueError("merge input contains multiple FPGA bins; use --group-by-fpga-bin")
        fpga_bin, group_items = next(iter(groups.items()))
        used_ids: set[str] = set()
        cases = [
            _case_for_merge(case, case_id=_unique_case_id(case.case_id, used_ids), source_path=path)
            for path, case in group_items
        ]
        suite = _merged_suite(name=base_name, defaults=base_defaults, fpga_bin=fpga_bin, cases=cases)
        out = options.out.expanduser().resolve()
        _write_suite(out, suite, overwrite=options.overwrite)
        return {
            "suite": out,
            "name": suite.name,
            "fpga_bin": fpga_bin,
            "case_count": len(cases),
            "execution_count": len({case.exec_key for case in cases}),
            "logical_duplicate_count": logical_duplicate_count,
            "dropped_duplicate_count": logical_duplicate_count,
        }

    out_dir = options.out.expanduser().resolve()
    if out_dir.exists() and not out_dir.is_dir():
        raise FileExistsError(f"group output path exists and is not a directory: {out_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    index_path = out_dir / "index.yaml"
    if index_path.exists() and not options.overwrite:
        raise FileExistsError(f"merged suite index already exists; use --overwrite: {index_path}")

    generated: list[dict[str, Any]] = []
    for fpga_bin, group_items in sorted(groups.items()):
        used_ids: set[str] = set()
        cases = [
            _case_for_merge(case, case_id=_unique_case_id(case.case_id, used_ids), source_path=path)
            for path, case in group_items
        ]
        suite_name = sanitize_id(f"{base_name}__{fpga_bin}")
        suite = _merged_suite(name=suite_name, defaults=base_defaults, fpga_bin=fpga_bin, cases=cases)
        suite_path = out_dir / f"{suite_name}.yaml"
        _write_suite(suite_path, suite, overwrite=options.overwrite)
        generated.append({
            "suite": str(suite_path),
            "name": suite.name,
            "fpga_bin": fpga_bin,
            "apps": sorted({case.app for case in cases if case.app}),
            "kinds": sorted({case.kind for case in cases if case.kind}),
            "backends": sorted({case.backend for case in cases if case.backend}),
            "case_count": len(cases),
            "execution_count": len({case.exec_key for case in cases}),
            "run_command": _run_command(suite_path, out_dir / suite.name),
        })

    index: dict[str, Any] = {
        "input_suites": [str(path) for path in suite_paths],
        "output_dir": str(out_dir),
        "logical_duplicate_count": logical_duplicate_count,
        "dropped_duplicate_count": logical_duplicate_count,
        "execution_count": len(execution_keys),
        "generated": generated,
    }
    with index_path.open("w") as fp:
        yaml.safe_dump(index, fp, sort_keys=False)
    return {"index": index_path, **index}
