from __future__ import annotations

import hashlib
import itertools
import json
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


DEFAULT_BLACKBOX_ARGS = ("--cores=1", "--threads=8")


def find_repo_root(start: Path | None = None) -> Path:
    start = Path.cwd() if start is None else start.resolve()
    for path in [start, *start.parents]:
        if (path / "tools" / "workload" / "gen_kernel_cfgs.py").exists():
            return path
    raise RuntimeError("Repository root not found")


def _ensure_repo_on_path(repo_root: Path) -> None:
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))


def sanitize_id(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    value = re.sub(r"_+", "_", value).strip("_")
    return value or "case"


def stable_hash(value: str, n: int = 10) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:n]


@dataclass(frozen=True)
class BenchDefaults:
    app: str = "fpint_gemm_ffn_hw"
    target: str = "hw"
    platform: str = "xilinx_u55c_gen3x16_xdma_3_202210_1"
    warmup: int = 3
    iterations: int = 10
    xrt_device_index: int = 0
    blackbox_args: tuple[str, ...] = DEFAULT_BLACKBOX_ARGS


@dataclass(frozen=True)
class BenchCase:
    case_id: str
    app: str
    args: str
    kind: str = ""
    stage: str = ""
    name: str = ""
    calls_per_forward: float = 1.0
    shape: dict[str, Any] = field(default_factory=dict)
    warmup: int = 3
    iterations: int = 10
    source: str = "explicit"

    @property
    def exec_key(self) -> str:
        payload = {
            "app": self.app,
            "args": " ".join(self.args.split()),
            "warmup": self.warmup,
            "iterations": self.iterations,
        }
        return stable_hash(json.dumps(payload, sort_keys=True))


@dataclass(frozen=True)
class BenchSuite:
    name: str
    defaults: BenchDefaults
    cases: list[BenchCase]
    source_path: Path | None = None


def _merge_defaults(raw: dict[str, Any]) -> BenchDefaults:
    defaults = raw.get("defaults") or {}
    blackbox_args_raw = defaults.get("blackbox_args", DEFAULT_BLACKBOX_ARGS)
    if isinstance(blackbox_args_raw, str):
        blackbox_args = tuple(shlex.split(blackbox_args_raw))
    else:
        blackbox_args = tuple(str(arg) for arg in blackbox_args_raw)
    return BenchDefaults(
        app=str(defaults.get("app", BenchDefaults.app)),
        target=str(defaults.get("target", BenchDefaults.target)),
        platform=str(defaults.get("platform", BenchDefaults.platform)),
        warmup=int(defaults.get("warmup", BenchDefaults.warmup)),
        iterations=int(defaults.get("iterations", BenchDefaults.iterations)),
        xrt_device_index=int(defaults.get("xrt_device_index", BenchDefaults.xrt_device_index)),
        blackbox_args=blackbox_args,
    )


def _case_from_raw(raw: dict[str, Any], defaults: BenchDefaults, index: int) -> BenchCase:
    args = str(raw.get("args", "")).strip()
    if not args:
        raise ValueError(f"case #{index} is missing non-empty args")
    name = str(raw.get("name", raw.get("id", f"case_{index}")))
    case_id = sanitize_id(str(raw.get("id", name)))
    return BenchCase(
        case_id=case_id,
        app=str(raw.get("app", defaults.app)),
        args=args,
        kind=str(raw.get("kind", "")),
        stage=str(raw.get("stage", "")),
        name=name,
        calls_per_forward=float(raw.get("calls_per_forward", 1)),
        shape=dict(raw.get("shape") or {}),
        warmup=int(raw.get("warmup", defaults.warmup)),
        iterations=int(raw.get("iterations", defaults.iterations)),
        source="explicit",
    )


def _pow2_values(start: int, end: int) -> list[int]:
    if start <= 0 or end < start:
        raise ValueError(f"invalid pow2 range: [{start}, {end}]")
    if start & (start - 1) or end & (end - 1):
        raise ValueError(f"pow2 range endpoints must be powers of two: [{start}, {end}]")
    values = []
    value = start
    while value <= end:
        values.append(value)
        value *= 2
    return values


def _matrix_values(spec: Any) -> list[Any]:
    if isinstance(spec, dict):
        if "values" in spec:
            values = spec["values"]
            if not isinstance(values, list):
                raise ValueError(f"matrix values must be a list: {spec}")
            return values
        if "pow2" in spec:
            bounds = spec["pow2"]
            if not isinstance(bounds, list) or len(bounds) != 2:
                raise ValueError(f"pow2 matrix spec must be [start, end]: {spec}")
            return _pow2_values(int(bounds[0]), int(bounds[1]))
        raise ValueError(f"unknown matrix spec: {spec}")
    if isinstance(spec, list):
        return spec
    return [spec]


def _format_value(value: Any, params: dict[str, Any]) -> Any:
    if isinstance(value, str):
        formatted = value.format(**params)
        if re.fullmatch(r"-?\d+", formatted):
            return int(formatted)
        try:
            return float(formatted) if re.fullmatch(r"-?\d+\.\d+", formatted) else formatted
        except ValueError:
            return formatted
    if isinstance(value, dict):
        return {key: _format_value(inner, params) for key, inner in value.items()}
    if isinstance(value, list):
        return [_format_value(inner, params) for inner in value]
    return value


def _expand_case_matrix(raw: dict[str, Any], defaults: BenchDefaults, index: int) -> list[BenchCase]:
    matrix = raw.get("matrix")
    if not isinstance(matrix, dict) or not matrix:
        raise ValueError(f"case_matrix #{index} is missing non-empty matrix")

    keys = list(matrix.keys())
    value_lists = [_matrix_values(matrix[key]) for key in keys]
    prefix = sanitize_id(str(raw.get("id", f"matrix_{index}")))

    cases = []
    for combo in itertools.product(*value_lists):
        params = dict(zip(keys, combo))
        case_id_template = str(raw.get("case_id", raw.get("name", prefix)))
        name_template = str(raw.get("name", case_id_template))
        args_template = str(raw.get("args", "")).strip()
        if not args_template:
            raise ValueError(f"case_matrix #{index} is missing non-empty args template")

        case_id = sanitize_id(str(_format_value(case_id_template, params)))
        name = str(_format_value(name_template, params))
        shape = _format_value(raw.get("shape", {}), params)
        if not isinstance(shape, dict):
            raise ValueError(f"case_matrix #{index} shape must expand to a mapping")

        cases.append(BenchCase(
            case_id=case_id,
            app=str(raw.get("app", defaults.app)),
            args=str(_format_value(args_template, params)),
            kind=str(raw.get("kind", "")),
            stage=str(raw.get("stage", "")),
            name=name,
            calls_per_forward=float(raw.get("calls_per_forward", 1)),
            shape=shape,
            warmup=int(raw.get("warmup", defaults.warmup)),
            iterations=int(raw.get("iterations", defaults.iterations)),
            source=f"case_matrix:{prefix}",
        ))

    return cases


def _expand_workload(raw: dict[str, Any], defaults: BenchDefaults, repo_root: Path) -> list[BenchCase]:
    _ensure_repo_on_path(repo_root)
    from tools.workload.gen_kernel_cfgs import build_llm_kernels

    model = str(raw["model"])
    stage_raw = raw.get("stage", "all")
    stages = ["prefill", "generation"] if stage_raw == "all" else [s.strip() for s in str(stage_raw).split(",") if s.strip()]
    payload = build_llm_kernels(
        model_name=model,
        stages=stages,
        batch=int(raw.get("batch", 1)),
        prefill_seq_len=int(raw.get("prefill_seq_len", raw.get("prefill-seq-len", 128))),
        gen_kv_len=int(raw.get("gen_kv_len", raw.get("gen-kv-len", 128))),
        qblk=int(raw.get("qblk", 32)),
    )

    implemented_only = bool(raw.get("implemented_only", True))
    filter_kind = raw.get("filter_kind")
    prefix = sanitize_id(str(raw.get("id", f"{model}_{'_'.join(stages)}")))
    cases: list[BenchCase] = []
    seen_ids: set[str] = set()

    for i, kernel in enumerate(payload["kernels"], start=1):
        if implemented_only and not kernel.get("implemented", False):
            continue
        if filter_kind and kernel.get("kind") != filter_kind:
            continue
        app = kernel.get("app")
        args = str(kernel.get("args", "")).strip()
        if not app or not args:
            continue
        base_id = sanitize_id(f"{prefix}_{kernel.get('stage', '')}_{kernel.get('name', kernel.get('kind', 'kernel'))}")
        case_id = base_id
        suffix = 2
        while case_id in seen_ids:
            case_id = f"{base_id}_{suffix}"
            suffix += 1
        seen_ids.add(case_id)
        cases.append(BenchCase(
            case_id=case_id,
            app=str(app),
            args=args,
            kind=str(kernel.get("kind", "")),
            stage=str(kernel.get("stage", "")),
            name=str(kernel.get("name", case_id)),
            calls_per_forward=float(kernel.get("calls_per_forward", 1)),
            shape=dict(kernel.get("shape") or {}),
            warmup=int(raw.get("warmup", defaults.warmup)),
            iterations=int(raw.get("iterations", defaults.iterations)),
            source=f"workload:{model}:{i}",
        ))

    return cases


def load_suite(path: Path, repo_root: Path | None = None,
               warmup_override: int | None = None,
               iterations_override: int | None = None) -> BenchSuite:
    repo_root = find_repo_root() if repo_root is None else repo_root
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"suite must be a YAML mapping: {path}")

    defaults = _merge_defaults(raw)
    if warmup_override is not None:
        defaults = BenchDefaults(**{**defaults.__dict__, "warmup": int(warmup_override)})
    if iterations_override is not None:
        defaults = BenchDefaults(**{**defaults.__dict__, "iterations": int(iterations_override)})

    cases: list[BenchCase] = []
    for i, item in enumerate(raw.get("cases") or [], start=1):
        cases.append(_case_from_raw(item, defaults, i))
    for i, item in enumerate(raw.get("case_matrices") or [], start=1):
        cases.extend(_expand_case_matrix(item, defaults, i))
    for item in raw.get("workloads") or []:
        cases.extend(_expand_workload(item, defaults, repo_root))

    if not cases:
        raise ValueError(f"suite has no runnable cases: {path}")

    return BenchSuite(
        name=sanitize_id(str(raw.get("name", path.stem))),
        defaults=defaults,
        cases=cases,
        source_path=path,
    )


def suite_to_rows(suite: BenchSuite) -> list[dict[str, Any]]:
    rows = []
    for case in suite.cases:
        rows.append({
            "suite": suite.name,
            "case_id": case.case_id,
            "exec_key": case.exec_key,
            "app": case.app,
            "kind": case.kind,
            "stage": case.stage,
            "name": case.name,
            "args": case.args,
            "shape_json": json.dumps(case.shape, sort_keys=True),
            "calls_per_forward": case.calls_per_forward,
            "warmup": case.warmup,
            "iterations": case.iterations,
            "source": case.source,
        })
    return rows


def suite_to_expanded_yaml(suite: BenchSuite) -> dict[str, Any]:
    defaults = dict(suite.defaults.__dict__)
    defaults["blackbox_args"] = list(suite.defaults.blackbox_args)

    cases = []
    for case in suite.cases:
        row: dict[str, Any] = {
            "id": case.case_id,
            "app": case.app,
            "kind": case.kind,
            "stage": case.stage,
            "name": case.name,
            "args": case.args,
            "calls_per_forward": case.calls_per_forward,
            "warmup": case.warmup,
            "iterations": case.iterations,
        }
        if case.shape:
            row["shape"] = case.shape
        cases.append(row)

    return {
        "name": suite.name,
        "defaults": defaults,
        "cases": cases,
    }
