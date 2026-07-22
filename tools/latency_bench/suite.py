from __future__ import annotations

import hashlib
import itertools
import json
import re
import shlex
import sys
import ast
import copy
import fnmatch
import operator
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

import yaml


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
    blackbox_args: tuple[str, ...] = ()
    blackbox_timeout: str = ""
    fpga_bin: str = ""


@dataclass(frozen=True)
class BenchCase:
    case_id: str
    app: str
    args: str
    kind: str = ""
    op: str = ""
    backend: str = ""
    variant: str = ""
    stage: str = ""
    name: str = ""
    calls_per_forward: float = 1.0
    shape: dict[str, Any] = field(default_factory=dict)
    warmup: int = 3
    iterations: int = 10
    source: str = "explicit"
    fpga_bin: str = ""

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
    fpga_bins: dict[str, Any] = field(default_factory=dict)
    source_path: Path | None = None


@dataclass(frozen=True)
class LoadedSuiteArtifacts:
    suite: BenchSuite
    workload_structures: list[dict[str, Any]]


@dataclass(frozen=True)
class SuiteMatrixOverrides:
    batch_values: tuple[int, ...] = ()
    seq_len_values: tuple[int, ...] = ()
    prefill_batch_values: tuple[int, ...] = ()
    generation_batch_values: tuple[int, ...] = ()
    prefill_seq_len_values: tuple[int, ...] = ()
    generation_seq_len_values: tuple[int, ...] = ()


_SEQ_LEN_MATRIX_KEYS = ("prefill_seq_len", "gen_kv_len", "seq_len", "seq")
_PREFILL_SEQ_LEN_MATRIX_KEYS = ("prefill_seq_len", "seq_len", "seq")
_GENERATION_SEQ_LEN_MATRIX_KEYS = ("gen_kv_len", "seq_len", "seq")
_STAGES_WITH_CONFIG = {"prefill", "generation"}


def _matrix_values_spec(values: tuple[int, ...]) -> dict[str, list[int]]:
    return {"values": [int(value) for value in values]}


def _has_suite_matrix_overrides(overrides: SuiteMatrixOverrides) -> bool:
    return any((
        overrides.batch_values,
        overrides.seq_len_values,
        overrides.prefill_batch_values,
        overrides.generation_batch_values,
        overrides.prefill_seq_len_values,
        overrides.generation_seq_len_values,
    ))


def _has_stage_specific_matrix_overrides(overrides: SuiteMatrixOverrides) -> bool:
    return any((
        overrides.prefill_batch_values,
        overrides.generation_batch_values,
        overrides.prefill_seq_len_values,
        overrides.generation_seq_len_values,
    ))


def _stage_tokens(raw_stage: Any) -> set[str]:
    stage = str(raw_stage or "").strip()
    if not stage or stage == "all":
        return set(_STAGES_WITH_CONFIG)
    return {part.strip() for part in stage.split(",") if part.strip()}


def _batch_values_for_stage(overrides: SuiteMatrixOverrides, stage: str) -> tuple[int, ...]:
    if stage == "prefill" and overrides.prefill_batch_values:
        return overrides.prefill_batch_values
    if stage == "generation" and overrides.generation_batch_values:
        return overrides.generation_batch_values
    return overrides.batch_values


def _seq_len_values_for_stage(overrides: SuiteMatrixOverrides, stage: str) -> tuple[int, ...]:
    if stage == "prefill" and overrides.prefill_seq_len_values:
        return overrides.prefill_seq_len_values
    if stage == "generation" and overrides.generation_seq_len_values:
        return overrides.generation_seq_len_values
    return overrides.seq_len_values


def _seq_len_keys_for_stage(stage: str) -> tuple[str, ...]:
    if stage == "prefill":
        return _PREFILL_SEQ_LEN_MATRIX_KEYS
    if stage == "generation":
        return _GENERATION_SEQ_LEN_MATRIX_KEYS
    return _SEQ_LEN_MATRIX_KEYS


def _apply_matrix_values_for_stage(
    item: dict[str, Any],
    overrides: SuiteMatrixOverrides,
    stage: str,
    *,
    split_stage_all: bool = False,
) -> dict[str, Any]:
    out = copy.deepcopy(item)
    matrix = out.get("matrix")
    if not isinstance(matrix, dict):
        return out

    if split_stage_all:
        out["stage"] = stage
        if "id" in out:
            out["id"] = f"{out['id']}_{stage}"
        if stage == "prefill":
            matrix.pop("gen_kv_len", None)
        elif stage == "generation":
            matrix.pop("prefill_seq_len", None)

    batch_values = _batch_values_for_stage(overrides, stage)
    if batch_values and "batch" in matrix:
        matrix["batch"] = _matrix_values_spec(batch_values)

    seq_len_values = _seq_len_values_for_stage(overrides, stage)
    if seq_len_values:
        for key in _seq_len_keys_for_stage(stage):
            if key in matrix:
                matrix[key] = _matrix_values_spec(seq_len_values)

    return out


def _apply_matrix_values_common(item: dict[str, Any], overrides: SuiteMatrixOverrides) -> dict[str, Any]:
    out = copy.deepcopy(item)
    matrix = out.get("matrix")
    if not isinstance(matrix, dict):
        return out
    if overrides.batch_values and "batch" in matrix:
        matrix["batch"] = _matrix_values_spec(overrides.batch_values)
    if overrides.seq_len_values:
        for key in _SEQ_LEN_MATRIX_KEYS:
            if key in matrix:
                matrix[key] = _matrix_values_spec(overrides.seq_len_values)
    return out


def _apply_case_matrix_overrides(item: dict[str, Any], overrides: SuiteMatrixOverrides) -> dict[str, Any]:
    stages = _stage_tokens(item.get("stage", ""))
    if stages == {"prefill"}:
        return _apply_matrix_values_for_stage(item, overrides, "prefill")
    if stages == {"generation"}:
        return _apply_matrix_values_for_stage(item, overrides, "generation")
    return _apply_matrix_values_common(item, overrides)


def _workload_needs_stage_split(item: dict[str, Any], overrides: SuiteMatrixOverrides) -> bool:
    matrix = item.get("matrix")
    if not isinstance(matrix, dict):
        return False
    if not _STAGES_WITH_CONFIG.issubset(_stage_tokens(item.get("stage", "all"))):
        return False
    if _has_stage_specific_matrix_overrides(overrides):
        return True
    return bool(
        overrides.seq_len_values
        and ("prefill_seq_len" in matrix or "gen_kv_len" in matrix)
    )


def _apply_workload_matrix_overrides(item: dict[str, Any], overrides: SuiteMatrixOverrides) -> list[dict[str, Any]]:
    if _workload_needs_stage_split(item, overrides):
        return [
            _apply_matrix_values_for_stage(item, overrides, "prefill", split_stage_all=True),
            _apply_matrix_values_for_stage(item, overrides, "generation", split_stage_all=True),
        ]

    stages = _stage_tokens(item.get("stage", "all"))
    if stages == {"prefill"}:
        return [_apply_matrix_values_for_stage(item, overrides, "prefill")]
    if stages == {"generation"}:
        return [_apply_matrix_values_for_stage(item, overrides, "generation")]
    return [_apply_matrix_values_common(item, overrides)]


def _apply_suite_matrix_overrides(raw: dict[str, Any], overrides: SuiteMatrixOverrides | None) -> dict[str, Any]:
    if overrides is None or not _has_suite_matrix_overrides(overrides):
        return raw

    out = copy.deepcopy(raw)
    case_matrices = out.get("case_matrices") or []
    if isinstance(case_matrices, list):
        out["case_matrices"] = [
            _apply_case_matrix_overrides(item, overrides) if isinstance(item, dict) else item
            for item in case_matrices
        ]

    workloads = out.get("workloads") or []
    if isinstance(workloads, list):
        replaced_workloads: list[Any] = []
        for item in workloads:
            if isinstance(item, dict):
                replaced_workloads.extend(_apply_workload_matrix_overrides(item, overrides))
            else:
                replaced_workloads.append(item)
        out["workloads"] = replaced_workloads

    return out


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


_FILTER_FIELDS = {
    "case_id",
    "app",
    "args",
    "kind",
    "op",
    "backend",
    "variant",
    "stage",
    "name",
    "calls_per_forward",
    "warmup",
    "iterations",
    "source",
    "fpga_bin",
}
_FILTER_FIELD_ALIASES = {"id": "case_id"}


@dataclass(frozen=True)
class _FilterToken:
    kind: str
    value: str


def _tokenize_case_filter(expr: str) -> list[_FilterToken]:
    tokens: list[_FilterToken] = []
    i = 0
    while i < len(expr):
        ch = expr[i]
        if ch.isspace():
            i += 1
            continue
        if ch in "&|()":
            tokens.append(_FilterToken(ch, ch))
            i += 1
            continue
        if ch == "!":
            if i + 1 < len(expr) and expr[i + 1] == "=":
                if i + 2 < len(expr) and expr[i + 2] == "~":
                    tokens.append(_FilterToken("OP", "!~"))
                    i += 3
                else:
                    tokens.append(_FilterToken("OP", "!="))
                    i += 2
            else:
                tokens.append(_FilterToken("!", "!"))
                i += 1
            continue
        if ch == "=":
            if i + 1 < len(expr) and expr[i + 1] == "~":
                tokens.append(_FilterToken("OP", "=~"))
                i += 2
                continue
            if i + 1 < len(expr) and expr[i + 1] == "=":
                i += 2
            else:
                i += 1
            tokens.append(_FilterToken("OP", "="))
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            value = []
            while i < len(expr):
                ch = expr[i]
                if ch == "\\" and i + 1 < len(expr):
                    value.append(expr[i + 1])
                    i += 2
                    continue
                if ch == quote:
                    i += 1
                    break
                value.append(ch)
                i += 1
            else:
                raise ValueError(f"unterminated quoted string in filter: {expr!r}")
            tokens.append(_FilterToken("ATOM", "".join(value)))
            continue

        start = i
        while i < len(expr) and not expr[i].isspace() and expr[i] not in "&|()!=":
            i += 1
        if i == start:
            raise ValueError(f"unexpected filter character {expr[i]!r} in {expr!r}")
        tokens.append(_FilterToken("ATOM", expr[start:i]))

    return tokens


def _case_filter_value(case: BenchCase, field_name: str) -> object:
    field_name = _FILTER_FIELD_ALIASES.get(field_name, field_name)
    if field_name.startswith("shape."):
        shape_key = field_name[len("shape."):]
        if not shape_key:
            raise ValueError("filter shape field must be shape.<key>")
        return case.shape.get(shape_key, "")
    if field_name not in _FILTER_FIELDS:
        supported = ", ".join(sorted(_FILTER_FIELDS | {"id", "shape.<key>"}))
        raise ValueError(f"unsupported filter field {field_name!r}; supported fields: {supported}")
    return getattr(case, field_name)


class _CaseFilterParser:
    def __init__(self, expr: str):
        self.expr = expr
        self.tokens = _tokenize_case_filter(expr)
        self.pos = 0

    def parse(self):
        if not self.tokens:
            raise ValueError("empty filter expression")
        node = self._parse_or()
        if self._peek() is not None:
            token = self._peek()
            raise ValueError(f"unexpected token {token.value!r} in filter: {self.expr!r}")
        return node

    def _peek(self) -> _FilterToken | None:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def _match(self, kind: str) -> bool:
        token = self._peek()
        if token is None or token.kind != kind:
            return False
        self.pos += 1
        return True

    def _expect(self, kind: str) -> _FilterToken:
        token = self._peek()
        if token is None or token.kind != kind:
            found = "end of expression" if token is None else repr(token.value)
            raise ValueError(f"expected {kind!r}, found {found} in filter: {self.expr!r}")
        self.pos += 1
        return token

    def _parse_or(self):
        node = self._parse_and()
        while self._match("|"):
            rhs = self._parse_and()
            node = (lambda lhs=node, rhs=rhs: lambda case: lhs(case) or rhs(case))()
        return node

    def _parse_and(self):
        node = self._parse_unary()
        while self._match("&"):
            rhs = self._parse_unary()
            node = (lambda lhs=node, rhs=rhs: lambda case: lhs(case) and rhs(case))()
        return node

    def _parse_unary(self):
        if self._match("!"):
            operand = self._parse_unary()
            return lambda case: not operand(case)
        return self._parse_primary()

    def _parse_primary(self):
        if self._match("("):
            node = self._parse_or()
            self._expect(")")
            return node
        return self._parse_comparison()

    def _parse_comparison(self):
        field_name = self._expect("ATOM").value
        op = self._expect("OP").value
        expected = self._expect("ATOM").value

        def compare(case: BenchCase) -> bool:
            actual = str(_case_filter_value(case, field_name))
            if op == "=":
                return actual == expected
            if op == "!=":
                return actual != expected
            if op == "=~":
                return fnmatch.fnmatchcase(actual, expected)
            if op == "!~":
                return not fnmatch.fnmatchcase(actual, expected)
            raise ValueError(f"unsupported filter operator {op!r}")

        return compare


def compile_case_filter(expr: str):
    return _CaseFilterParser(expr).parse()


def apply_case_filters(suite: BenchSuite, filters: tuple[str, ...]) -> BenchSuite:
    if not filters:
        return suite
    predicates = [compile_case_filter(expr) for expr in filters]
    cases = [case for case in suite.cases if all(predicate(case) for predicate in predicates)]
    return replace(suite, cases=cases)


def _merge_defaults(raw: dict[str, Any]) -> BenchDefaults:
    defaults = raw.get("defaults") or {}
    blackbox_args_raw = defaults.get("blackbox_args", ())
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
        blackbox_timeout=str(defaults.get("blackbox_timeout", "")),
        fpga_bin=str(defaults.get("fpga_bin", "")),
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
        op=str(raw.get("op", "")),
        backend=str(raw.get("backend", "")),
        variant=str(raw.get("variant", "")),
        stage=str(raw.get("stage", "")),
        name=name,
        calls_per_forward=float(raw.get("calls_per_forward", 1)),
        shape=dict(raw.get("shape") or {}),
        warmup=int(raw.get("warmup", defaults.warmup)),
        iterations=int(raw.get("iterations", defaults.iterations)),
        source="explicit",
        fpga_bin=str(raw.get("fpga_bin", "")),
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
        supported_keys = [key for key in ("values", "pow2", "pow") if key in spec]
        if len(supported_keys) != 1:
            raise ValueError(f"matrix spec must contain exactly one of values, pow2, or pow: {spec}")
        key = supported_keys[0]
        if key == "values":
            values = spec["values"]
            if not isinstance(values, list):
                raise ValueError(f"matrix values must be a list: {spec}")
            return values
        bounds = spec[key]
        if not isinstance(bounds, list) or len(bounds) != 2:
            raise ValueError(f"{key} matrix spec must be [start, end]: {spec}")
        return _pow2_values(int(bounds[0]), int(bounds[1]))
    if isinstance(spec, list):
        return spec
    return [spec]


_DERIVED_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}
_DERIVED_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}


def _eval_derived_expr(expr: str, params: dict[str, Any]) -> Any:
    def eval_node(node: ast.AST) -> Any:
        if isinstance(node, ast.Expression):
            return eval_node(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.Name):
            if node.id not in params:
                raise ValueError(f"unknown derived variable: {node.id}")
            value = params[node.id]
            if not isinstance(value, (int, float)):
                raise ValueError(f"derived variable must be numeric: {node.id}={value!r}")
            return value
        if isinstance(node, ast.BinOp) and type(node.op) in _DERIVED_BIN_OPS:
            return _DERIVED_BIN_OPS[type(node.op)](eval_node(node.left), eval_node(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in _DERIVED_UNARY_OPS:
            return _DERIVED_UNARY_OPS[type(node.op)](eval_node(node.operand))
        raise ValueError(f"unsupported derived expression: {expr!r}")

    parsed = ast.parse(expr, mode="eval")
    value = eval_node(parsed)
    return int(value) if isinstance(value, float) and value.is_integer() else value


def _apply_derived_params(
    params: dict[str, Any],
    raw: dict[str, Any],
    index: int,
    *,
    label: str = "case_matrix",
) -> dict[str, Any]:
    derived = raw.get("derived") or {}
    if not isinstance(derived, dict):
        raise ValueError(f"{label} #{index} derived must be a mapping")
    out = dict(params)
    for key, expr in derived.items():
        key = str(key)
        if key in out:
            raise ValueError(f"{label} #{index} derived key shadows matrix key: {key}")
        out[key] = _eval_derived_expr(str(expr), out)
    return out


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
        params = _apply_derived_params(dict(zip(keys, combo)), raw, index)
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
            app=str(_format_value(raw.get("app", defaults.app), params)),
            args=str(_format_value(args_template, params)),
            kind=str(_format_value(raw.get("kind", ""), params)),
            op=str(_format_value(raw.get("op", ""), params)),
            backend=str(_format_value(raw.get("backend", ""), params)),
            variant=str(_format_value(raw.get("variant", ""), params)),
            stage=str(_format_value(raw.get("stage", ""), params)),
            name=name,
            calls_per_forward=float(_format_value(raw.get("calls_per_forward", 1), params)),
            shape=shape,
            warmup=int(_format_value(raw.get("warmup", defaults.warmup), params)),
            iterations=int(_format_value(raw.get("iterations", defaults.iterations), params)),
            source=f"case_matrix:{prefix}",
            fpga_bin=str(_format_value(raw.get("fpga_bin", ""), params)),
        ))

    return cases


def _matrix_param_suffix(params: dict[str, Any]) -> str:
    return "_".join(
        f"{sanitize_id(str(key))}{sanitize_id(str(value))}"
        for key, value in params.items()
    )


def _format_workload_matrix_item(raw: dict[str, Any], params: dict[str, Any]) -> dict[str, Any]:
    out = {
        key: _format_value(value, params)
        for key, value in raw.items()
        if key not in ("matrix", "derived")
    }
    out.update(params)
    suffix = _matrix_param_suffix(params)
    raw_id = raw.get("id")
    if raw_id is None:
        out["id"] = f"{out.get('model', 'workload')}_{out.get('stage', 'all')}_{suffix}"
    else:
        formatted_id = str(_format_value(raw_id, params))
        out["id"] = formatted_id if "{" in str(raw_id) else f"{formatted_id}_{suffix}"
    return out


def _build_workload_payload(raw: dict[str, Any], repo_root: Path) -> dict[str, Any]:
    _ensure_repo_on_path(repo_root)
    from tools.workload.gen_kernel_cfgs import (
        DEFAULT_LLM_BATCH,
        DEFAULT_LLM_GEN_KV,
        DEFAULT_LLM_PREFILL_SEQ,
        DEFAULT_LLM_QBLK,
        DEFAULT_WORKLOAD_VARIANT,
        LLM_STAGES,
        build_llm_kernels,
    )

    model = str(raw["model"])
    stage_raw = raw.get("stage", "all")
    stages = list(LLM_STAGES) if stage_raw == "all" else [s.strip() for s in str(stage_raw).split(",") if s.strip()]
    max_seq_len_raw = raw.get("max_seq_len", raw.get("max-seq-len"))
    payload = build_llm_kernels(
        model_name=model,
        stages=stages,
        batch=int(raw.get("batch", DEFAULT_LLM_BATCH)),
        prefill_seq_len=int(raw.get("prefill_seq_len", raw.get("prefill-seq-len", DEFAULT_LLM_PREFILL_SEQ))),
        gen_kv_len=int(raw.get("gen_kv_len", raw.get("gen-kv-len", DEFAULT_LLM_GEN_KV))),
        qblk=int(raw.get("qblk", DEFAULT_LLM_QBLK)),
        variant=str(raw.get("variant", DEFAULT_WORKLOAD_VARIANT)),
        max_seq_len=(None if max_seq_len_raw is None else int(max_seq_len_raw)),
    )

    implemented_only = bool(raw.get("implemented_only", True))
    filter_kind = raw.get("filter_kind")
    filter_backend = raw.get("filter_backend")
    payload["kernels"] = [
        kernel for kernel in payload["kernels"]
        if not implemented_only or kernel.get("implemented", False)
    ]
    if filter_kind:
        payload["kernels"] = [
            kernel for kernel in payload["kernels"]
            if kernel.get("kind") == filter_kind
        ]
    if filter_backend:
        payload["kernels"] = [
            kernel for kernel in payload["kernels"]
            if kernel.get("backend") == filter_backend
        ]
    return payload


def _expand_workload_one(raw: dict[str, Any], defaults: BenchDefaults, payload: dict[str, Any]) -> list[BenchCase]:
    payload_stages = list((payload.get("config") or {}).get("stages") or [])
    prefix = sanitize_id(str(raw.get(
        "id",
        f"{payload.get('model', 'workload')}_{'_'.join(payload_stages)}",
    )))
    cases: list[BenchCase] = []
    seen_ids: set[str] = set()

    for i, kernel in enumerate(payload["kernels"], start=1):
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
            op=str(kernel.get("op", "")),
            backend=str(kernel.get("backend", "")),
            variant=str(kernel.get("variant", "")),
            stage=str(kernel.get("stage", "")),
            name=str(kernel.get("name", case_id)),
            calls_per_forward=float(kernel.get("calls_per_forward", 1)),
            shape=dict(kernel.get("shape") or {}),
            warmup=int(raw.get("warmup", defaults.warmup)),
            iterations=int(raw.get("iterations", defaults.iterations)),
            source=f"workload:{payload.get('model', 'workload')}:{kernel.get('variant', '')}:{i}",
        ))

    return cases


def _expand_workload_items(raw: dict[str, Any], index: int) -> Iterator[dict[str, Any]]:
    matrix = raw.get("matrix")
    if matrix is None:
        yield raw
        return
    if not isinstance(matrix, dict) or not matrix:
        raise ValueError(f"workload #{index} is missing non-empty matrix")

    keys = list(matrix.keys())
    value_lists = [_matrix_values(matrix[key]) for key in keys]
    for combo in itertools.product(*value_lists):
        yield _format_workload_matrix_item(
            raw,
            _apply_derived_params(dict(zip(keys, combo)), raw, index, label="workload"),
        )


def _expand_workload(
    raw: dict[str, Any],
    defaults: BenchDefaults,
    repo_root: Path,
    index: int,
    collect_structures: bool,
) -> tuple[list[BenchCase], list[dict[str, Any]]]:
    cases: list[BenchCase] = []
    structures: list[dict[str, Any]] = []
    for item in _expand_workload_items(raw, index):
        payload = _build_workload_payload(item, repo_root)
        if collect_structures:
            structures.append({
                "workload_id": sanitize_id(str(item.get("id", f"workload_{index}"))),
                **payload,
            })
        cases.extend(_expand_workload_one(item, defaults, payload))
    return cases, structures


def _load_suite_artifacts(path: Path, repo_root: Path | None = None,
                          warmup_override: int | None = None,
                          iterations_override: int | None = None,
                          matrix_overrides: SuiteMatrixOverrides | None = None,
                          collect_workload_structures: bool = False) -> LoadedSuiteArtifacts:
    repo_root = find_repo_root() if repo_root is None else repo_root
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"suite must be a YAML mapping: {path}")
    raw = _apply_suite_matrix_overrides(raw, matrix_overrides)

    defaults = _merge_defaults(raw)
    fpga_bins_raw = raw.get("fpga_bins") or {}
    if not isinstance(fpga_bins_raw, dict):
        raise ValueError(f"suite fpga_bins must be a YAML mapping: {path}")
    if warmup_override is not None:
        defaults = BenchDefaults(**{**defaults.__dict__, "warmup": int(warmup_override)})
    if iterations_override is not None:
        defaults = BenchDefaults(**{**defaults.__dict__, "iterations": int(iterations_override)})

    cases: list[BenchCase] = []
    workload_structures: list[dict[str, Any]] = []
    for i, item in enumerate(raw.get("cases") or [], start=1):
        cases.append(_case_from_raw(item, defaults, i))
    for i, item in enumerate(raw.get("case_matrices") or [], start=1):
        cases.extend(_expand_case_matrix(item, defaults, i))
    for i, item in enumerate(raw.get("workloads") or [], start=1):
        workload_cases, structures = _expand_workload(
            item,
            defaults,
            repo_root,
            i,
            collect_workload_structures,
        )
        cases.extend(workload_cases)
        workload_structures.extend(structures)

    if warmup_override is not None or iterations_override is not None:
        cases = [
            replace(
                case,
                warmup=defaults.warmup if warmup_override is not None else case.warmup,
                iterations=defaults.iterations if iterations_override is not None else case.iterations,
            )
            for case in cases
        ]

    if not cases:
        raise ValueError(f"suite has no runnable cases: {path}")

    return LoadedSuiteArtifacts(
        suite=BenchSuite(
            name=sanitize_id(str(raw.get("name", path.stem))),
            defaults=defaults,
            cases=cases,
            fpga_bins=dict(fpga_bins_raw),
            source_path=path,
        ),
        workload_structures=workload_structures,
    )


def load_suite_artifacts(path: Path, repo_root: Path | None = None,
                         warmup_override: int | None = None,
                         iterations_override: int | None = None,
                         matrix_overrides: SuiteMatrixOverrides | None = None) -> LoadedSuiteArtifacts:
    return _load_suite_artifacts(
        path,
        repo_root=repo_root,
        warmup_override=warmup_override,
        iterations_override=iterations_override,
        matrix_overrides=matrix_overrides,
        collect_workload_structures=True,
    )


def load_suite(path: Path, repo_root: Path | None = None,
               warmup_override: int | None = None,
               iterations_override: int | None = None,
               matrix_overrides: SuiteMatrixOverrides | None = None) -> BenchSuite:
    return _load_suite_artifacts(
        path,
        repo_root=repo_root,
        warmup_override=warmup_override,
        iterations_override=iterations_override,
        matrix_overrides=matrix_overrides,
    ).suite


def suite_to_rows(suite: BenchSuite) -> list[dict[str, Any]]:
    rows = []
    for case in suite.cases:
        rows.append({
            "suite": suite.name,
            "case_id": case.case_id,
            "exec_key": case.exec_key,
            "app": case.app,
            "kind": case.kind,
            "op": case.op,
            "backend": case.backend,
            "variant": case.variant,
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
    if suite.defaults.blackbox_args:
        defaults["blackbox_args"] = list(suite.defaults.blackbox_args)
    else:
        defaults.pop("blackbox_args", None)
    if not defaults.get("fpga_bin"):
        defaults.pop("fpga_bin", None)

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
        if case.op:
            row["op"] = case.op
        if case.backend:
            row["backend"] = case.backend
        if case.variant:
            row["variant"] = case.variant
        if case.shape:
            row["shape"] = case.shape
        if case.fpga_bin:
            row["fpga_bin"] = case.fpga_bin
        cases.append(row)

    out: dict[str, Any] = {
        "name": suite.name,
        "defaults": defaults,
        "cases": cases,
    }
    if suite.fpga_bins:
        out["fpga_bins"] = suite.fpga_bins
    return out
