from __future__ import annotations

import csv
import argparse
import json
import math
import os
import random
import shlex
import shutil
import subprocess
import time
from datetime import datetime, timezone
from collections import Counter, defaultdict
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

import pandas as pd

from .raw_db import RAW_DB_COLUMNS, _write_raw_rows
from .suite import (
    BenchCase,
    BenchSuite,
    bind_suite_xclbin_sha256,
    find_repo_root,
    load_suite,
    make_exec_key,
    stable_hash,
    suite_to_expanded_yaml,
    suite_to_rows,
)
from .yaml_io import safe_dump


RECOVERY_TYPE = "vortex-latency-interpolation-recovery"
RECOVERY_SCHEMA_VERSION = 1
TERMINAL_OUTCOMES = {
    "converged", "no_candidates", "budget_exhausted", "unbracketed",
}


@dataclass(frozen=True)
class InterpolationError:
    case_id: str
    kernel_type: str
    logical_cache_length: int
    predicted: float
    actual: float

    @property
    def absolute_error(self) -> float:
        return abs(self.predicted - self.actual)

    @property
    def relative_error(self) -> float:
        return self.absolute_error / max(abs(self.actual), 1e-9)


@dataclass(frozen=True)
class BracketedInterval:
    group_key: str
    stable_group_id: str
    lower_anchor: int
    upper_anchor: int
    candidates: tuple[BenchCase, ...]

    @property
    def width(self) -> int:
        return self.upper_anchor - self.lower_anchor

    @property
    def unique_exec_keys(self) -> int:
        return len({case.exec_key for case in self.candidates})


@dataclass(frozen=True)
class MidpointSelection:
    case: BenchCase
    interval: BracketedInterval
    rank: int
    reason: str

    @property
    def midpoint_relative_position(self) -> float:
        x = int(self.case.shape["logical_cache_length"])
        return (x - self.interval.lower_anchor) / self.interval.width


_DYNAMIC_SHAPE_KEYS = {
    "K", "N", "seqk", "cache_len", "maxseq", "logical_cache_length",
    "logical_kv_start", "logical_kv_end", "padded_cache_length",
    "output_token_index", "offset", "cache_position",
    "decode_sample_weight", "measurement_kind",
    "interpolation_lower_step", "interpolation_upper_step",
    "interpolation_upper_ratio", "reuse_representative_step",
}


def kernel_type(case: BenchCase) -> str:
    """Identify the physical kernel implementation used for interpolation."""
    return "|".join((case.app, case.backend))


def _kernel_type_filter(args: argparse.Namespace) -> set[str]:
    values = getattr(args, "kernel_types", []) or []
    parsed = {
        item.strip()
        for value in values
        for item in value.split(",")
        if item.strip()
    }
    if values and not parsed:
        raise ValueError("--kernel-type must contain at least one APP|BACKEND value")
    return parsed


def interpolation_group_key(case: BenchCase) -> str:
    stable_shape = {
        key: value for key, value in case.shape.items()
        if key not in _DYNAMIC_SHAPE_KEYS
    }
    return json.dumps({
        "kernel_type": kernel_type(case),
        "out_tokens": case.out_tokens,
        "shape": stable_shape,
    }, sort_keys=True, default=str)


def _raw_metric(path: Path, metric: str) -> tuple[dict[str, float], dict[str, dict[str, str]]]:
    values: dict[str, float] = {}
    rows: dict[str, dict[str, str]] = {}
    if not path.exists():
        return values, rows
    with path.open(newline="") as fp:
        for row in csv.DictReader(fp):
            if row.get("status") != "pass":
                continue
            try:
                value = float(row.get(metric, ""))
            except (TypeError, ValueError):
                continue
            if not math.isfinite(value):
                continue
            exec_key = make_exec_key(
                row.get("xclbin_sha256", ""),
                row.get("app", ""),
                row.get("args", ""),
            )
            row["exec_key"] = exec_key
            values[exec_key] = value
            rows[exec_key] = row
    return values, rows


def predict_case(
    case: BenchCase,
    group: list[BenchCase],
    raw_values: dict[str, float],
) -> float | None:
    points = sorted({
        (int(item.shape["logical_cache_length"]), raw_values[item.exec_key])
        for item in group
        if item.exec_key in raw_values and "logical_cache_length" in item.shape
    })
    x = int(case.shape["logical_cache_length"])
    lower = [point for point in points if point[0] <= x]
    upper = [point for point in points if point[0] >= x]
    if not lower or not upper:
        return None
    lo, hi = lower[-1], upper[0]
    if lo[0] == hi[0]:
        return lo[1]
    ratio = (x - lo[0]) / (hi[0] - lo[0])
    return lo[1] * (1.0 - ratio) + hi[1] * ratio


def interpolation_candidates(suite: BenchSuite) -> list[BenchCase]:
    return [case for case in suite.cases if case.measurement_kind == "interpolated"]


def unresolved_interpolation_candidates(
    suite: BenchSuite,
    raw_db: Path,
    metric: str = "p50_us",
) -> list[BenchCase]:
    raw_values, _ = _raw_metric(raw_db, metric)
    return [
        case for case in interpolation_candidates(suite)
        if case.exec_key not in raw_values
    ]


def _case_cache_length(case: BenchCase) -> int:
    return int(case.shape["logical_cache_length"])


def _representatives_nearest_midpoint(
    cases: list[BenchCase] | tuple[BenchCase, ...],
    lower: int,
    upper: int,
) -> list[BenchCase]:
    midpoint = (lower + upper) / 2
    by_exec_key: dict[str, list[BenchCase]] = defaultdict(list)
    for case in cases:
        by_exec_key[case.exec_key].append(case)
    return [
        min(
            matching,
            key=lambda case: (
                abs(_case_cache_length(case) - midpoint),
                _case_cache_length(case),
                case.case_id,
            ),
        )
        for _, matching in sorted(by_exec_key.items())
    ]


def bracketed_intervals(
    suite: BenchSuite,
    raw_values: dict[str, float],
    *,
    physical_kernel: str,
) -> tuple[list[BracketedInterval], list[BenchCase]]:
    """Return measured-anchor intervals and extrapolation-only candidates."""
    groups: dict[str, list[BenchCase]] = defaultdict(list)
    for case in suite.cases:
        if kernel_type(case) == physical_kernel:
            groups[interpolation_group_key(case)].append(case)

    intervals: list[BracketedInterval] = []
    unbracketed: list[BenchCase] = []
    for group_key in sorted(groups):
        group = groups[group_key]
        anchors = sorted({
            _case_cache_length(case)
            for case in group
            if case.exec_key in raw_values
            and "logical_cache_length" in case.shape
        })
        candidates = [
            case for case in group
            if case.measurement_kind == "interpolated"
            and case.exec_key not in raw_values
            and "logical_cache_length" in case.shape
        ]
        bracketed_case_ids: set[str] = set()
        for lower, upper in zip(anchors, anchors[1:]):
            matching = tuple(
                case for case in candidates
                if lower < _case_cache_length(case) < upper
            )
            if not matching:
                continue
            intervals.append(BracketedInterval(
                group_key=group_key,
                stable_group_id=stable_hash(group_key),
                lower_anchor=lower,
                upper_anchor=upper,
                candidates=matching,
            ))
            bracketed_case_ids.update(case.case_id for case in matching)
        unbracketed.extend(
            case for case in candidates if case.case_id not in bracketed_case_ids
        )
    intervals.sort(key=lambda interval: (
        -interval.unique_exec_keys,
        -interval.width,
        interval.stable_group_id,
        interval.lower_anchor,
        interval.upper_anchor,
    ))
    return intervals, unbracketed


def _choose_segment_midpoint(
    interval: BracketedInterval,
    cases: list[BenchCase],
    lower: int,
    upper: int,
    used_exec_keys: set[str],
) -> BenchCase | None:
    available = [
        case for case in cases
        if case.exec_key not in used_exec_keys
        and lower < _case_cache_length(case) < upper
    ]
    representatives = _representatives_nearest_midpoint(available, lower, upper)
    if not representatives:
        return None
    midpoint = (lower + upper) / 2
    return min(representatives, key=lambda case: (
        abs(_case_cache_length(case) - midpoint),
        _case_cache_length(case),
        case.exec_key,
        case.case_id,
    ))


def select_midpoint_candidates(
    intervals: list[BracketedInterval],
    sample_count: int,
) -> list[MidpointSelection]:
    """Spread across base intervals, then bisect their largest remaining spans."""
    if sample_count <= 0:
        return []
    selected: list[MidpointSelection] = []
    used_exec_keys: set[str] = set()
    segments: list[tuple[BracketedInterval, int, int, list[BenchCase]]] = []

    def select_from_segment(
        interval: BracketedInterval,
        lower: int,
        upper: int,
        cases: list[BenchCase],
        reason: str,
    ) -> None:
        case = _choose_segment_midpoint(
            interval, cases, lower, upper, used_exec_keys
        )
        if case is None:
            return
        used_exec_keys.add(case.exec_key)
        selected.append(MidpointSelection(
            case=case,
            interval=interval,
            rank=len(selected) + 1,
            reason=reason,
        ))
        x = _case_cache_length(case)
        for sub_lower, sub_upper in ((lower, x), (x, upper)):
            sub_cases = [
                item for item in cases
                if item.exec_key not in used_exec_keys
                and sub_lower < _case_cache_length(item) < sub_upper
            ]
            if sub_cases:
                segments.append((interval, sub_lower, sub_upper, sub_cases))

    for interval in intervals:
        if len(selected) >= sample_count:
            break
        select_from_segment(
            interval,
            interval.lower_anchor,
            interval.upper_anchor,
            list(interval.candidates),
            "distinct_interval_midpoint",
        )

    while len(selected) < sample_count and segments:
        segments.sort(key=lambda item: (
            -len({
                case.exec_key for case in item[3]
                if case.exec_key not in used_exec_keys
            }),
            -(item[2] - item[1]),
            item[0].stable_group_id,
            item[1],
            item[2],
        ))
        interval, lower, upper, cases = segments.pop(0)
        select_from_segment(
            interval, lower, upper, cases, "virtual_bisection_midpoint"
        )
    return selected


def sample_candidates(
    suite: BenchSuite,
    samples_per_kernel: int,
    seed: int,
    *,
    candidates: list[BenchCase] | None = None,
) -> list[BenchCase]:
    grouped: dict[str, list[BenchCase]] = defaultdict(list)
    for case in interpolation_candidates(suite) if candidates is None else candidates:
        grouped[kernel_type(case)].append(case)
    rng = random.Random(seed)
    selected = []
    for key in sorted(grouped):
        cases = grouped[key]
        selected.extend(rng.sample(cases, min(samples_per_kernel, len(cases))))
    return selected


def evaluate_cases(
    suite: BenchSuite,
    candidates: list[BenchCase],
    baseline_raw_db: Path,
    probe_raw_db: Path,
    metric: str,
) -> list[InterpolationError]:
    baseline, _ = _raw_metric(baseline_raw_db, metric)
    actual, _ = _raw_metric(probe_raw_db, metric)
    return evaluate_cases_from_values(suite, candidates, baseline, actual)


def evaluate_cases_from_values(
    suite: BenchSuite,
    candidates: list[BenchCase],
    baseline: dict[str, float],
    actual: dict[str, float],
) -> list[InterpolationError]:
    groups: dict[str, list[BenchCase]] = defaultdict(list)
    for case in suite.cases:
        groups[interpolation_group_key(case)].append(case)
    errors = []
    for case in candidates:
        leave_one_out = dict(baseline)
        leave_one_out.pop(case.exec_key, None)
        predicted = predict_case(
            case, groups[interpolation_group_key(case)], leave_one_out
        )
        if predicted is None or case.exec_key not in actual:
            continue
        errors.append(InterpolationError(
            case.case_id, kernel_type(case),
            int(case.shape["logical_cache_length"]),
            predicted, actual[case.exec_key],
        ))
    return errors


def write_error_outputs(errors: list[InterpolationError], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = [{
        **error.__dict__,
        "absolute_error": error.absolute_error,
        "relative_error": error.relative_error,
    } for error in errors]
    error_columns = [
        "case_id", "kernel_type", "logical_cache_length",
        "predicted", "actual", "absolute_error", "relative_error",
    ]
    pd.DataFrame(rows, columns=error_columns).to_csv(
        out_dir / "errors.csv", index=False
    )
    summaries = []
    for key, group in pd.DataFrame(rows).groupby("kernel_type") if rows else []:
        rel = group["relative_error"]
        summaries.append({
            "kernel_type": key,
            "samples": len(group),
            "mean_relative_error": rel.mean(),
            "p95_relative_error": rel.quantile(0.95),
            "max_relative_error": rel.max(),
            "mean_absolute_error": group["absolute_error"].mean(),
        })
    summary_columns = [
        "kernel_type", "samples", "mean_relative_error",
        "p95_relative_error", "max_relative_error", "mean_absolute_error",
    ]
    pd.DataFrame(summaries, columns=summary_columns).to_csv(
        out_dir / "summary.csv", index=False
    )


def write_candidate_suite(suite: BenchSuite, cases: list[BenchCase], path: Path) -> None:
    selected = [
        replace(
            case,
            measurement_kind="measured",
            shape={**case.shape, "measurement_kind": "measured"},
        )
        for case in cases
    ]
    candidate_suite = replace(suite, name=f"{suite.name}_interpolation_probe", cases=selected)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fp:
        safe_dump(suite_to_expanded_yaml(candidate_suite), fp, sort_keys=False)


def run_measurement_command(template: str, suite_path: Path, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    command = template.format(suite=str(suite_path), out=str(out_dir))
    subprocess.run(shlex.split(command), check=True)
    raw_db = out_dir / "raw_db.csv"
    if not raw_db.exists():
        raise FileNotFoundError(f"measurement command did not create {raw_db}")
    return raw_db


def reweight_suite_for_exec_keys(
    suite: BenchSuite,
    available_exec_keys: set[str],
) -> BenchSuite:
    groups: dict[str, list[BenchCase]] = defaultdict(list)
    for case in suite.cases:
        groups[interpolation_group_key(case)].append(case)
    replacements: dict[str, BenchCase] = {}
    for group in groups.values():
        continuous = any(
            case.shape.get("decode_sampling_class") == "continuous" for case in group
        )
        if not continuous:
            continue
        ordered = sorted(group, key=lambda case: int(case.shape["logical_cache_length"]))
        anchors = [
            i for i, case in enumerate(ordered)
            if case.exec_key in available_exec_keys
        ]
        if not anchors:
            continue
        for index, case in enumerate(ordered):
            measured = index in anchors
            shape = dict(case.shape)
            shape["measurement_kind"] = (
                "promoted"
                if measured and case.measurement_kind == "interpolated"
                else case.measurement_kind
            )
            replacements[case.case_id] = replace(
                case,
                measurement_kind=shape["measurement_kind"],
                shape=shape,
            )
    return replace(
        suite,
        cases=[replacements.get(case.case_id, case) for case in suite.cases],
    )


def refined_suite(suite: BenchSuite, raw_db: Path, metric: str = "p50_us") -> BenchSuite:
    raw_values, _ = _raw_metric(raw_db, metric)
    return reweight_suite_for_exec_keys(suite, set(raw_values))


def write_current_cases(
    suite: BenchSuite,
    raw_db: Path,
    path: Path,
    metric: str = "p50_us",
    *,
    raw_values: dict[str, float] | None = None,
) -> None:
    current_suite = (
        reweight_suite_for_exec_keys(suite, set(raw_values))
        if raw_values is not None
        else refined_suite(suite, raw_db, metric)
    )
    rows = suite_to_rows(current_suite)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as fp:
        writer = csv.DictWriter(
            fp,
            fieldnames=list(rows[0].keys()) if rows else [],
        )
        if rows:
            writer.writeheader()
            writer.writerows(rows)


def _atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    shutil.copy2(source, temporary)
    temporary.replace(destination)


def publish_latest(
    artifact_dir: Path,
    output_root: Path,
    category: str,
    filenames: list[str],
) -> None:
    latest = output_root / "latest"
    _atomic_copy(artifact_dir / "cases.csv", latest / "cases.csv")
    for filename in filenames:
        source = artifact_dir / filename
        if source.exists():
            _atomic_copy(source, latest / category / filename)


def _artifact_dir(
    args: argparse.Namespace,
    category: str,
    id_value: str | None,
) -> tuple[Path, Path]:
    if args.output_root:
        root = Path(args.output_root)
        artifact_id = id_value or datetime.now(timezone.utc).strftime(
            "%Y%m%dT%H%M%S%fZ"
        )
        return root, root / "interpolation" / category / artifact_id
    if not args.out:
        raise ValueError("--output-root or --out is required")
    if not args.raw_db:
        raise ValueError("--raw-db is required when --out is used")
    out = Path(args.out)
    return Path(args.raw_db).parent, out


def _main_raw_db(args: argparse.Namespace, output_root: Path) -> Path:
    return Path(args.raw_db) if args.raw_db else output_root / "raw_db.csv"


def _raw_measurement_overrides(raw_db: Path) -> tuple[int | None, int | None]:
    if not raw_db.exists():
        return None, None
    counts: Counter[tuple[int, int]] = Counter()
    with raw_db.open(newline="") as fp:
        for row in csv.DictReader(fp):
            if row.get("status") != "pass":
                continue
            try:
                counts[(int(row["warmup"]), int(row["iterations"]))] += 1
            except (KeyError, TypeError, ValueError):
                continue
    if not counts:
        return None, None
    return counts.most_common(1)[0][0]


def _load_suite_for_raw(suite_path: Path, raw_db: Path) -> BenchSuite:
    warmup, iterations = _raw_measurement_overrides(raw_db)
    suite = load_suite(
        suite_path,
        repo_root=find_repo_root(),
        warmup_override=warmup,
        iterations_override=iterations,
    )
    if suite.experiment:
        return suite
    xclbin_counts: Counter[str] = Counter()
    if raw_db.exists():
        with raw_db.open(newline="") as fp:
            for row in csv.DictReader(fp):
                sha = str(row.get("xclbin_sha256", "")).strip()
                if row.get("status") == "pass" and sha:
                    xclbin_counts[sha] += 1
    if xclbin_counts:
        suite = bind_suite_xclbin_sha256(suite, xclbin_counts.most_common(1)[0][0])
    return suite


def promote_probe_rows(
    main_raw_db: Path,
    probe_raw_db: Path,
    exec_keys: set[str],
    metric: str = "p50_us",
    *,
    existing_values: dict[str, float] | None = None,
    existing_rows: dict[str, dict[str, str]] | None = None,
) -> int:
    probe_values, probe_rows = _raw_metric(probe_raw_db, metric)
    if existing_values is None:
        existing_values, _ = _raw_metric(main_raw_db, metric)
    rows = []
    added_keys: list[str] = []
    added = 0
    for key in sorted(exec_keys):
        if key in existing_values or key not in probe_rows:
            continue
        row = {column: probe_rows[key].get(column, "") for column in RAW_DB_COLUMNS}
        rows.append(row)
        added_keys.append(key)
        added += 1
    _write_raw_rows(
        rows, main_raw_db, mode="upsert", run_id="interpolation_refine"
    )
    for key in added_keys:
        existing_values[key] = probe_values[key]
        if existing_rows is not None:
            existing_rows[key] = probe_rows[key]
    return added


def p95(errors: list[InterpolationError]) -> float:
    if not errors:
        return math.inf
    values = sorted(error.relative_error for error in errors)
    return values[min(len(values) - 1, math.ceil(0.95 * len(values)) - 1)]


def _json_digest(value: Any) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), default=str,
        allow_nan=False,
    )
    return stable_hash(encoded, n=64)


def _suite_identity(suite: BenchSuite) -> str:
    return _json_digest(suite_to_expanded_yaml(suite))


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as output:
            json.dump(payload, output, indent=2, sort_keys=True, allow_nan=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _load_recovery_checkpoint(path: Path) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as source:
            payload = json.load(source)
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid refinement recovery checkpoint {path}: {error}") from error
    if payload.get("type") != RECOVERY_TYPE:
        raise ValueError(f"unsupported refinement recovery checkpoint type in {path}")
    if payload.get("schema_version") != RECOVERY_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported refinement recovery checkpoint schema in {path}: "
            f"{payload.get('schema_version')!r}"
        )
    return payload


def _save_recovery_checkpoint(path: Path, checkpoint: dict[str, Any]) -> None:
    checkpoint["updated_at"] = datetime.now(timezone.utc).isoformat()
    checkpoint["completed_budget"] = sum(
        int(state.get("completed_iterations", 0))
        for state in checkpoint["kernels"].values()
    )
    checkpoint["terminal_outcomes"] = {
        key: state.get("terminal_outcome")
        for key, state in checkpoint["kernels"].items()
        if state.get("terminal_outcome")
    }
    active = [
        state["active_iteration"]
        for state in checkpoint["kernels"].values()
        if state.get("active_iteration") is not None
    ]
    checkpoint["active_iteration"] = active[0] if len(active) == 1 else None
    _atomic_write_json(path, checkpoint)


def _recovery_identity(
    suite: BenchSuite,
    args: argparse.Namespace,
    kernel_types: list[str],
) -> dict[str, Any]:
    return {
        "suite_identity": _suite_identity(suite),
        "metric": args.metric,
        "sampling_strategy": args.sampling_strategy,
        "seed": args.seed,
        "validation_samples": args.validation_samples,
        "kernel_types": kernel_types,
    }


def _relevant_values(
    suite: BenchSuite,
    raw_values: dict[str, float],
    kernel_types: set[str],
) -> dict[str, float]:
    relevant_keys = {
        case.exec_key for case in suite.cases if kernel_type(case) in kernel_types
    }
    return {
        key: raw_values[key] for key in sorted(relevant_keys & set(raw_values))
    }


def _self_observation_values(checkpoint: dict[str, Any]) -> dict[str, float]:
    values = {
        key: float(value)
        for key, value in checkpoint.get("accepted_post_state", {}).items()
    }
    for kernel_state in checkpoint.get("kernels", {}).values():
        active = kernel_state.get("active_iteration") or {}
        values.update({
            key: float(value)
            for key, value in active.get("actual_values", {}).items()
        })
    return values


def _external_anchor_values(
    suite: BenchSuite,
    raw_values: dict[str, float],
    kernel_types: set[str],
    self_values: dict[str, float],
) -> dict[str, float]:
    return {
        key: value
        for key, value in _relevant_values(suite, raw_values, kernel_types).items()
        if key not in self_values or value != self_values[key]
    }


def _new_recovery_checkpoint(
    suite: BenchSuite,
    args: argparse.Namespace,
    kernel_types: list[str],
    raw_values: dict[str, float],
    grouped_candidates: dict[str, list[BenchCase]],
    *,
    archived_epochs: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    rng = random.Random(args.seed)
    kernels: dict[str, dict[str, Any]] = {}
    for key in kernel_types:
        random_order = [
            case.exec_key for case in grouped_candidates.get(key, [])
            if case.exec_key not in raw_values
        ]
        rng.shuffle(random_order)
        kernels[key] = {
            "physical_kernel": key,
            "completed_iterations": 0,
            "terminal_outcome": None,
            "random_order": random_order,
            "remaining_order": list(random_order),
            "active_iteration": None,
        }
    identity = _recovery_identity(suite, args, kernel_types)
    return {
        "type": RECOVERY_TYPE,
        "schema_version": RECOVERY_SCHEMA_VERSION,
        "epoch_id": _json_digest({
            "identity": identity,
            "external_anchors": _external_anchor_values(
                suite, raw_values, set(kernel_types), {}
            ),
        })[:16],
        "epoch_identity": identity,
        "external_anchor_values": _external_anchor_values(
            suite, raw_values, set(kernel_types), {}
        ),
        "policy": {
            "target_error": args.target_error,
            "max_iterations": args.max_iterations,
            "require_convergence": bool(getattr(args, "require_convergence", False)),
        },
        "phase": "ready",
        "kernels": kernels,
        "history": [],
        "errors": [],
        "selections": [],
        "accepted_post_state": {},
        "completed_budget": 0,
        "terminal_outcomes": {},
        "active_iteration": None,
        "archived_epochs": archived_epochs or [],
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def _archive_epoch(checkpoint: dict[str, Any], reason: str) -> list[dict[str, Any]]:
    archived = list(checkpoint.get("archived_epochs", []))
    archived.append({
        "epoch_id": checkpoint.get("epoch_id"),
        "epoch_identity": checkpoint.get("epoch_identity"),
        "external_anchor_values": checkpoint.get("external_anchor_values", {}),
        "history": checkpoint.get("history", []),
        "errors": checkpoint.get("errors", []),
        "selections": checkpoint.get("selections", []),
        "accepted_post_state": checkpoint.get("accepted_post_state", {}),
        "completed_budget": checkpoint.get("completed_budget", 0),
        "terminal_outcomes": checkpoint.get("terminal_outcomes", {}),
        "superseded_reason": reason,
    })
    return archived


def _restore_or_create_checkpoint(
    path: Path,
    suite: BenchSuite,
    args: argparse.Namespace,
    kernel_types: list[str],
    raw_values: dict[str, float],
    grouped_candidates: dict[str, list[BenchCase]],
) -> dict[str, Any]:
    checkpoint = _load_recovery_checkpoint(path)
    if checkpoint is None:
        checkpoint = _new_recovery_checkpoint(
            suite, args, kernel_types, raw_values, grouped_candidates
        )
        _save_recovery_checkpoint(path, checkpoint)
        return checkpoint

    identity = _recovery_identity(suite, args, kernel_types)
    reason = ""
    if checkpoint.get("epoch_identity") != identity:
        reason = "suite or sampling identity changed"
    else:
        current_external = _external_anchor_values(
            suite,
            raw_values,
            set(kernel_types),
            _self_observation_values(checkpoint),
        )
        if current_external != checkpoint.get("external_anchor_values", {}):
            reason = "relevant external anchors changed"
    if reason:
        checkpoint = _new_recovery_checkpoint(
            suite,
            args,
            kernel_types,
            raw_values,
            grouped_candidates,
            archived_epochs=_archive_epoch(checkpoint, reason),
        )
    checkpoint["policy"] = {
        "target_error": args.target_error,
        "max_iterations": args.max_iterations,
        "require_convergence": bool(getattr(args, "require_convergence", False)),
    }
    _save_recovery_checkpoint(path, checkpoint)
    return checkpoint


def _error_payload(error: InterpolationError, *, iteration_id: str) -> dict[str, Any]:
    return {
        **error.__dict__,
        "absolute_error": error.absolute_error,
        "relative_error": error.relative_error,
        "iteration_id": iteration_id,
    }


def _errors_from_active(active: dict[str, Any]) -> list[InterpolationError]:
    return [
        InterpolationError(
            case_id=row["case_id"],
            kernel_type=row["kernel_type"],
            logical_cache_length=int(row["logical_cache_length"]),
            predicted=float(row["predicted"]),
            actual=float(row["actual"]),
        )
        for row in active.get("errors", [])
    ]


def _probe_references(
    rows: dict[str, dict[str, str]],
    keys: set[str],
    probe_raw: Path,
) -> dict[str, dict[str, str]]:
    references: dict[str, dict[str, str]] = {}
    for key in sorted(keys & set(rows)):
        row = rows[key]
        references[key] = {
            "run_id": row.get("run_id", ""),
            "raw_db": str(probe_raw.resolve()),
            "raw_csv": row.get("raw_csv", ""),
            "log_file": row.get("log_file", ""),
        }
    return references


def _midpoint_counts(
    suite: BenchSuite,
    raw_values: dict[str, float],
    kernel_types: list[str],
) -> tuple[int, int, int]:
    interval_count = 0
    bracketed_keys: set[tuple[str, str]] = set()
    unbracketed_keys: set[tuple[str, str]] = set()
    for key in kernel_types:
        intervals, unbracketed = bracketed_intervals(
            suite, raw_values, physical_kernel=key
        )
        interval_count += len(intervals)
        bracketed_keys.update(
            (key, case.exec_key)
            for interval in intervals for case in interval.candidates
        )
        unbracketed_keys.update((key, case.exec_key) for case in unbracketed)
    return interval_count, len(bracketed_keys), len(unbracketed_keys)


def write_refinement_progress(
    *,
    suite: BenchSuite,
    main_raw: Path,
    probe_raw: Path | None,
    output_root: Path,
    out: Path,
    args: argparse.Namespace,
    grouped: dict[str, list[BenchCase]],
    unresolved: list[BenchCase],
    raw_values: dict[str, float],
    history: list[dict[str, Any]],
    selections: list[dict[str, Any]],
    status: str,
    checkpoint: dict[str, Any] | None = None,
) -> None:
    kernel_type_filter = _kernel_type_filter(args)
    iteration_columns = [
        "kernel_type",
        "iteration",
        "sampling_strategy",
        "bracketed_intervals",
        "bracketed_candidates",
        "unbracketed_candidates",
        "validation_samples",
        "p95_relative_error",
        "target_error",
        "status",
        "promoted_measurements",
    ]
    pd.DataFrame(history, columns=iteration_columns).to_csv(
        out / "iterations.csv", index=False
    )
    selection_columns = [
        "kernel_type", "iteration", "stable_group_id", "case_id", "exec_key",
        "logical_cache_length", "lower_anchor", "upper_anchor",
        "interval_width", "interval_candidate_count",
        "midpoint_relative_position", "selection_rank", "selection_reason",
    ]
    pd.DataFrame(selections, columns=selection_columns).to_csv(
        out / "selections.csv", index=False
    )
    error_columns = [
        "iteration_id", "case_id", "kernel_type", "logical_cache_length",
        "predicted", "actual", "absolute_error", "relative_error",
    ]
    pd.DataFrame(
        checkpoint.get("errors", []) if checkpoint else [],
        columns=error_columns,
    ).to_csv(out / "errors.csv", index=False)
    write_current_cases(
        suite, main_raw, out / "cases.csv", args.metric, raw_values=raw_values
    )
    interval_count, bracketed_count, unbracketed_count = _midpoint_counts(
        suite, raw_values, sorted(grouped)
    )
    (out / "state.json").write_text(json.dumps({
        "suite": str(Path(args.suite).resolve()),
        "output_root": str(output_root.resolve()),
        "raw_db": str(main_raw.resolve()),
        "probe_raw_db": str(probe_raw.resolve()) if probe_raw else "",
        "target_error": args.target_error,
        "max_iterations": args.max_iterations,
        "seed": args.seed,
        "sampling_strategy": args.sampling_strategy,
        "kernel_type_filter": sorted(kernel_type_filter),
        "kernel_types": len(grouped),
        "bracketed_intervals": interval_count,
        "bracketed_candidates": bracketed_count,
        "unbracketed_candidates": unbracketed_count,
        "initial_unresolved_cases": len(unresolved),
        "remaining_unresolved_cases": sum(
            case.exec_key not in raw_values
            and (not kernel_type_filter or kernel_type(case) in kernel_type_filter)
            for case in interpolation_candidates(suite)
        ),
        "promoted_measurements": sum(
            int(item.get("promoted_measurements", 0)) for item in history
        ),
        "completed_budget": (
            int(checkpoint.get("completed_budget", 0)) if checkpoint else len(history)
        ),
        "terminal_outcomes": (
            checkpoint.get("terminal_outcomes", {}) if checkpoint else {}
        ),
        "recovery_checkpoint": str((out / "recovery.json").resolve()),
        "status": status,
    }, indent=2) + "\n")
    publish_latest(
        out,
        output_root,
        "refinement",
        ["iterations.csv", "selections.csv", "errors.csv", "state.json", "recovery.json"],
    )


def evaluate_command(args: argparse.Namespace) -> int:
    output_root, out = _artifact_dir(
        args, "evaluations", args.evaluation_id
    )
    raw_db = _main_raw_db(args, output_root)
    suite = _load_suite_for_raw(Path(args.suite), raw_db)
    candidates = unresolved_interpolation_candidates(suite, raw_db, args.metric)
    selected = sample_candidates(
        suite, args.samples_per_kernel, args.seed, candidates=candidates
    )
    write_candidate_suite(suite, selected, out / "probe_suite.yaml")
    manifest = {
        "suite": str(Path(args.suite).resolve()),
        "output_root": str(output_root.resolve()),
        "baseline_raw_db": str(raw_db.resolve()),
        "probe_raw_db": str(Path(args.probe_raw_db).resolve()) if args.probe_raw_db else "",
        "samples_per_kernel": args.samples_per_kernel,
        "seed": args.seed,
        "candidate_count": len(selected),
        "status": "no_candidates" if not selected else "ready",
        "promoted_measurements": 0,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if not selected:
        write_error_outputs([], out)
        write_current_cases(suite, raw_db, out / "cases.csv", args.metric)
        publish_latest(
            out,
            output_root,
            "evaluation",
            ["errors.csv", "summary.csv", "manifest.json", "probe_suite.yaml"],
        )
        print("no unresolved interpolation cases; nothing to evaluate")
        return 0
    probe_raw_db = Path(args.probe_raw_db) if args.probe_raw_db else None
    if probe_raw_db is None and args.measure_command:
        probe_run = out / "probe_run"
        try:
            probe_raw_db = run_measurement_command(
                args.measure_command, out / "probe_suite.yaml", probe_run
            )
        except (KeyboardInterrupt, subprocess.CalledProcessError):
            partial_raw = probe_run / "raw_db.csv"
            errors = (
                evaluate_cases(suite, selected, raw_db, partial_raw, args.metric)
                if partial_raw.exists() else []
            )
            write_error_outputs(errors, out)
            promoted = (
                promote_probe_rows(
                    raw_db,
                    partial_raw,
                    {case.exec_key for case in selected},
                    args.metric,
                )
                if partial_raw.exists() else 0
            )
            manifest.update({
                "probe_raw_db": str(partial_raw.resolve()) if partial_raw.exists() else "",
                "evaluated_cases": len(errors),
                "promoted_measurements": promoted,
                "status": "interrupted",
            })
            (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            write_current_cases(suite, raw_db, out / "cases.csv", args.metric)
            publish_latest(
                out,
                output_root,
                "evaluation",
                ["errors.csv", "summary.csv", "manifest.json", "probe_suite.yaml"],
            )
            raise
    if probe_raw_db:
        errors = evaluate_cases(
            suite, selected, raw_db, probe_raw_db, args.metric
        )
        write_error_outputs(errors, out)
        promoted = promote_probe_rows(
            raw_db,
            probe_raw_db,
            {case.exec_key for case in selected},
            args.metric,
        )
        manifest.update({
            "probe_raw_db": str(probe_raw_db.resolve()),
            "evaluated_cases": len(errors),
            "promoted_measurements": promoted,
            "status": "completed",
        })
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        write_current_cases(suite, raw_db, out / "cases.csv", args.metric)
        publish_latest(
            out,
            output_root,
            "evaluation",
            ["errors.csv", "summary.csv", "manifest.json", "probe_suite.yaml"],
        )
        print(
            f"evaluated {len(errors)}/{len(selected)} interpolation probes; "
            f"promoted {promoted} measurements"
        )
    else:
        write_error_outputs([], out)
        write_current_cases(suite, raw_db, out / "cases.csv", args.metric)
        publish_latest(
            out,
            output_root,
            "evaluation",
            ["errors.csv", "summary.csv", "manifest.json", "probe_suite.yaml"],
        )
        print(f"wrote {len(selected)} probes; run {out / 'probe_suite.yaml'} into a separate probe raw DB")
    return 0


def refine_command(args: argparse.Namespace) -> int:
    started = time.monotonic()
    output_root, out = _artifact_dir(
        args, "refinements", args.refinement_id or "default"
    )
    main_raw = _main_raw_db(args, output_root)
    out.mkdir(parents=True, exist_ok=True)
    checkpoint_path = out / "recovery.json"
    suite = _load_suite_for_raw(Path(args.suite), main_raw)
    raw_values, raw_rows = _raw_metric(main_raw, args.metric)
    candidates = interpolation_candidates(suite)
    kernel_type_filter = _kernel_type_filter(args)
    available_kernel_types = {kernel_type(case) for case in candidates}
    unknown_kernel_types = kernel_type_filter - available_kernel_types
    if unknown_kernel_types:
        raise ValueError(
            "unknown --kernel-type value(s): "
            f"{', '.join(sorted(unknown_kernel_types))}; available: "
            f"{', '.join(sorted(available_kernel_types))}"
        )
    ordered_groups = sorted(kernel_type_filter or available_kernel_types)
    grouped_candidates: dict[str, list[BenchCase]] = defaultdict(list)
    for case in candidates:
        if kernel_type(case) in ordered_groups:
            grouped_candidates[kernel_type(case)].append(case)

    # Restore recovery state before discovering which candidates remain.  A
    # promoted row is therefore interpreted through its saved iteration first.
    checkpoint = _restore_or_create_checkpoint(
        checkpoint_path,
        suite,
        args,
        ordered_groups,
        raw_values,
        grouped_candidates,
    )
    history = checkpoint["history"]
    selections = checkpoint["selections"]
    probe_raw = Path(args.probe_raw_db) if args.probe_raw_db else None
    unresolved = [
        case for case in candidates
        if kernel_type(case) in ordered_groups and case.exec_key not in raw_values
    ]
    if unresolved and not args.probe_raw_db and not args.measure_command:
        raise ValueError("refine requires --probe-raw-db or --measure-command")

    print(
        f"[refine] start metric={args.metric} target_p95={args.target_error:.2%} "
        f"max_iterations={args.max_iterations} validation_samples={args.validation_samples} "
        f"sampling_strategy={args.sampling_strategy} epoch={checkpoint['epoch_id']}",
        flush=True,
    )
    print(f"[refine] artifacts={out.resolve()}", flush=True)

    case_by_id = {case.case_id: case for case in suite.cases}
    case_by_exec: dict[str, BenchCase] = {}
    for case in candidates:
        case_by_exec.setdefault(case.exec_key, case)
    curve_groups: dict[str, list[BenchCase]] = defaultdict(list)
    for case in suite.cases:
        curve_groups[interpolation_group_key(case)].append(case)

    def save(phase: str) -> None:
        checkpoint["phase"] = phase
        _save_recovery_checkpoint(checkpoint_path, checkpoint)

    def report(status: str) -> None:
        write_refinement_progress(
            suite=suite,
            main_raw=main_raw,
            probe_raw=probe_raw,
            output_root=output_root,
            out=out,
            args=args,
            grouped=grouped_candidates,
            unresolved=unresolved,
            raw_values=raw_values,
            history=history,
            selections=selections,
            status=status,
            checkpoint=checkpoint,
        )

    # Mutable policy parameters do not create an epoch.  Reevaluate saved
    # evidence and budget before selecting any further probes.
    for key in ordered_groups:
        kernel_state = checkpoint["kernels"][key]
        kernel_history = [row for row in history if row["kernel_type"] == key]
        latest = kernel_history[-1] if kernel_history else None
        completed = int(kernel_state["completed_iterations"])
        if latest and float(latest["p95_relative_error"]) <= args.target_error:
            if kernel_state.get("active_iteration") is not None:
                kernel_state["deferred_iteration"] = kernel_state.pop(
                    "active_iteration"
                )
            kernel_state["terminal_outcome"] = "converged"
        elif kernel_state.get("terminal_outcome") == "no_candidates":
            pass
        elif kernel_state.get("terminal_outcome") == "unbracketed":
            pass
        elif completed >= args.max_iterations:
            if kernel_state.get("active_iteration") is not None:
                kernel_state["deferred_iteration"] = kernel_state.pop(
                    "active_iteration"
                )
            kernel_state["terminal_outcome"] = "budget_exhausted"
        else:
            if (
                kernel_state.get("active_iteration") is None
                and kernel_state.get("deferred_iteration") is not None
            ):
                kernel_state["active_iteration"] = kernel_state.pop(
                    "deferred_iteration"
                )
            kernel_state["terminal_outcome"] = None
    save("ready")
    report("running")

    for kernel_index, key in enumerate(ordered_groups, start=1):
        kernel_state = checkpoint["kernels"][key]
        while kernel_state.get("terminal_outcome") is None:
            active = kernel_state.get("active_iteration")
            if active is None:
                completed = int(kernel_state["completed_iterations"])
                if completed >= args.max_iterations:
                    kernel_state["terminal_outcome"] = "budget_exhausted"
                    save("committed")
                    break
                intervals, unbracketed = bracketed_intervals(
                    suite, raw_values, physical_kernel=key
                )
                bracketed_count = len({
                    case.exec_key
                    for interval in intervals for case in interval.candidates
                })
                unbracketed_count = len({case.exec_key for case in unbracketed})
                midpoint_selections: list[MidpointSelection] = []
                if args.sampling_strategy == "midpoint":
                    midpoint_selections = select_midpoint_candidates(
                        intervals, args.validation_samples
                    )
                    validation = [item.case for item in midpoint_selections]
                    selection_rows = [{
                        "kernel_type": key,
                        "iteration": completed,
                        "stable_group_id": item.interval.stable_group_id,
                        "case_id": item.case.case_id,
                        "exec_key": item.case.exec_key,
                        "logical_cache_length": _case_cache_length(item.case),
                        "lower_anchor": item.interval.lower_anchor,
                        "upper_anchor": item.interval.upper_anchor,
                        "interval_width": item.interval.width,
                        "interval_candidate_count": item.interval.unique_exec_keys,
                        "midpoint_relative_position": item.midpoint_relative_position,
                        "selection_rank": item.rank,
                        "selection_reason": item.reason,
                    } for item in midpoint_selections]
                else:
                    remaining = [
                        exec_key for exec_key in kernel_state["remaining_order"]
                        if exec_key not in raw_values
                    ]
                    selected_keys = remaining[:args.validation_samples]
                    validation = [case_by_exec[exec_key] for exec_key in selected_keys]
                    kernel_state["remaining_order"] = remaining[len(selected_keys):]
                    selection_rows = [{
                        "kernel_type": key,
                        "iteration": completed,
                        "stable_group_id": stable_hash(interpolation_group_key(case)),
                        "case_id": case.case_id,
                        "exec_key": case.exec_key,
                        "logical_cache_length": _case_cache_length(case),
                        "lower_anchor": "",
                        "upper_anchor": "",
                        "interval_width": "",
                        "interval_candidate_count": "",
                        "midpoint_relative_position": "",
                        "selection_rank": rank,
                        "selection_reason": "random_seed",
                    } for rank, case in enumerate(validation, start=1)]
                if not validation:
                    has_unresolved = any(
                        case.exec_key not in raw_values
                        for case in grouped_candidates[key]
                    )
                    kernel_state["terminal_outcome"] = (
                        "unbracketed" if has_unresolved else "no_candidates"
                    )
                    save("committed")
                    break

                baseline_values = dict(raw_values)
                predictions = {
                    case.exec_key: predict_case(
                        case,
                        curve_groups[interpolation_group_key(case)],
                        baseline_values,
                    )
                    for case in validation
                }
                iteration_id = f"{checkpoint['epoch_id']}-{key}-{completed}"
                iteration_id = stable_hash(iteration_id, n=16)
                selected_keys = {case.exec_key for case in validation}
                anchor_evidence = [{
                    "exec_key": exec_key,
                    "value": baseline_values[exec_key],
                    "run_id": raw_rows.get(exec_key, {}).get("run_id", ""),
                    "raw_db": str(main_raw.resolve()),
                } for exec_key in sorted(baseline_values) if exec_key not in selected_keys]
                iteration_probe = (
                    Path(args.probe_raw_db)
                    if args.probe_raw_db
                    else out / "validation_runs" / iteration_id / "raw_db.csv"
                )
                active = {
                    "iteration_id": iteration_id,
                    "iteration": completed,
                    "physical_kernel": key,
                    "selected_case_ids": [case.case_id for case in validation],
                    "selected_exec_keys": [case.exec_key for case in validation],
                    "selection_rows": selection_rows,
                    "frozen_predictions": predictions,
                    "anchor_evidence": anchor_evidence,
                    "probe_db": str(iteration_probe.resolve()),
                    "original_run_refs": {},
                    "actual_values": {},
                    "errors": [],
                    "phase": "selected",
                }
                kernel_state["active_iteration"] = active
                selections.extend(selection_rows)
                save("selected")
            else:
                validation = [case_by_id[case_id] for case_id in active["selected_case_ids"]]

            selected_keys = set(active["selected_exec_keys"])
            iteration_probe = Path(active["probe_db"])
            probe_values, probe_rows = _raw_metric(iteration_probe, args.metric)
            recovered_values = {
                key_: probe_values[key_] for key_ in selected_keys & set(probe_values)
            }
            for key_ in selected_keys - set(recovered_values):
                if key_ in raw_values and (
                    key_ in checkpoint["accepted_post_state"]
                    or active.get("phase") in {"evaluated", "promoted"}
                ):
                    recovered_values[key_] = raw_values[key_]
                    if key_ in raw_rows:
                        probe_rows[key_] = raw_rows[key_]
            missing_keys = selected_keys - set(recovered_values)
            if missing_keys and args.measure_command:
                missing_cases = [case for case in validation if case.exec_key in missing_keys]
                validation_suite = out / f"validate_{active['iteration_id']}.yaml"
                write_candidate_suite(suite, missing_cases, validation_suite)
                try:
                    probe_raw = run_measurement_command(
                        args.measure_command, validation_suite, iteration_probe.parent
                    )
                    active["probe_db"] = str(probe_raw.resolve())
                    iteration_probe = probe_raw
                except (KeyboardInterrupt, subprocess.CalledProcessError):
                    partial_values, partial_rows = _raw_metric(iteration_probe, args.metric)
                    active["actual_values"].update({
                        key_: partial_values[key_]
                        for key_ in selected_keys & set(partial_values)
                    })
                    active["original_run_refs"].update(
                        _probe_references(partial_rows, selected_keys, iteration_probe)
                    )
                    active["phase"] = "interrupted"
                    save("interrupted")
                    report("interrupted")
                    raise
                probe_values, probe_rows = _raw_metric(iteration_probe, args.metric)
                recovered_values.update({
                    key_: probe_values[key_]
                    for key_ in selected_keys & set(probe_values)
                })
            probe_raw = iteration_probe
            missing_keys = selected_keys - set(recovered_values)
            if missing_keys:
                active["actual_values"] = recovered_values
                active["original_run_refs"].update(
                    _probe_references(probe_rows, selected_keys, iteration_probe)
                )
                active["phase"] = "failed"
                active["missing_exec_keys"] = sorted(missing_keys)
                save("failed")
                report("failed")
                print(
                    f"[refine] failed iteration={active['iteration_id']} "
                    f"missing_probes={len(missing_keys)}",
                    flush=True,
                )
                return 1

            active["actual_values"] = recovered_values
            active["original_run_refs"].update(
                _probe_references(probe_rows, selected_keys, iteration_probe)
            )
            active["phase"] = "probed"
            save("probed")

            if not active.get("errors"):
                active["errors"] = []
                for case in validation:
                    predicted = active["frozen_predictions"].get(case.exec_key)
                    if predicted is None:
                        continue
                    error = InterpolationError(
                        case_id=case.case_id,
                        kernel_type=key,
                        logical_cache_length=_case_cache_length(case),
                        predicted=float(predicted),
                        actual=float(recovered_values[case.exec_key]),
                    )
                    payload = _error_payload(
                        error, iteration_id=active["iteration_id"]
                    )
                    payload["exec_key"] = case.exec_key
                    active["errors"].append(payload)
            errors = _errors_from_active(active)
            if len(errors) != len(validation):
                active["phase"] = "failed"
                active["missing_predictions"] = sorted(
                    selected_keys - {row["exec_key"] for row in active["errors"]}
                )
                save("failed")
                report("failed")
                return 1
            active["phase"] = "evaluated"
            save("evaluated")

            promote_probe_rows(
                main_raw,
                iteration_probe,
                selected_keys,
                args.metric,
                existing_values=raw_values,
                existing_rows=raw_rows,
            )
            checkpoint["accepted_post_state"].update({
                key_: recovered_values[key_] for key_ in sorted(selected_keys)
            })
            active["phase"] = "promoted"
            save("promoted")

            current_p95 = p95(errors)
            converged = current_p95 <= args.target_error
            history_row = {
                "kernel_type": key,
                "iteration": int(active["iteration"]),
                "iteration_id": active["iteration_id"],
                "sampling_strategy": args.sampling_strategy,
                "bracketed_intervals": len(bracketed_intervals(
                    suite,
                    {item["exec_key"]: float(item["value"])
                     for item in active["anchor_evidence"]},
                    physical_kernel=key,
                )[0]),
                "bracketed_candidates": len(active["selected_exec_keys"]),
                "unbracketed_candidates": 0,
                "validation_samples": len(errors),
                "p95_relative_error": current_p95,
                "target_error": args.target_error,
                "status": "converged" if converged else "refining",
                "promoted_measurements": len(selected_keys),
                "selected_exec_keys": list(active["selected_exec_keys"]),
                "frozen_predictions": dict(active["frozen_predictions"]),
                "anchor_evidence": list(active["anchor_evidence"]),
                "probe_db": active["probe_db"],
                "original_run_refs": dict(active["original_run_refs"]),
                "phase": "committed",
            }
            if not any(
                row.get("iteration_id") == active["iteration_id"] for row in history
            ):
                history.append(history_row)
                checkpoint["errors"].extend(active["errors"])
                kernel_state["completed_iterations"] = (
                    int(kernel_state["completed_iterations"]) + 1
                )
            kernel_state["terminal_outcome"] = "converged" if converged else None
            kernel_state["active_iteration"] = None
            save("committed")
            report("running")
            print(
                f"[refine] kernel {kernel_index}/{len(ordered_groups)} "
                f"iteration={history_row['iteration'] + 1} "
                f"p95={current_p95:.2%} promoted={len(selected_keys)}",
                flush=True,
            )

    outcomes = {
        key: checkpoint["kernels"][key].get("terminal_outcome")
        for key in ordered_groups
    }
    if not ordered_groups:
        overall_status = "no_candidates"
    elif all(outcome in TERMINAL_OUTCOMES for outcome in outcomes.values()):
        overall_status = "completed"
    else:
        overall_status = "failed"
    save("terminal")
    report(overall_status)
    print(
        f"[refine] complete outcomes={outcomes} completed_budget="
        f"{checkpoint['completed_budget']} elapsed={time.monotonic() - started:.1f}s",
        flush=True,
    )
    if getattr(args, "require_convergence", False):
        acceptable = {"converged", "no_candidates"}
        if any(outcome not in acceptable for outcome in outcomes.values()):
            return 2
    return 0


def add_cli_parsers(sub: argparse._SubParsersAction) -> None:
    evaluate = sub.add_parser("evaluate-interpolation")
    evaluate.add_argument("--suite", required=True)
    evaluate.add_argument("--output-root")
    evaluate.add_argument("--raw-db")
    evaluate.add_argument("--probe-raw-db")
    evaluate.add_argument(
        "--measure-command",
        help="Runner command template containing {suite} and {out}.",
    )
    evaluate.add_argument("--out")
    evaluate.add_argument("--evaluation-id")
    evaluate.add_argument("--samples-per-kernel", type=int, default=5)
    evaluate.add_argument("--seed", type=int, default=0)
    evaluate.add_argument("--metric", default="p50_us")

    refine = sub.add_parser("refine-interpolation")
    refine.add_argument("--suite", required=True)
    refine.add_argument("--output-root")
    refine.add_argument("--raw-db")
    refine.add_argument("--probe-raw-db")
    refine.add_argument(
        "--measure-command",
        help="Runner command template containing {suite} and {out}.",
    )
    refine.add_argument("--out")
    refine.add_argument("--refinement-id")
    refine.add_argument("--target-error", type=float, required=True)
    refine.add_argument(
        "--samples-per-iteration",
        type=int,
        default=2,
        help=(
            "Deprecated compatibility option; every measured validation sample "
            "is now promoted."
        ),
    )
    refine.add_argument("--validation-samples", type=int, default=3)
    refine.add_argument("--max-iterations", type=int, default=10)
    refine.add_argument(
        "--kernel-type",
        dest="kernel_types",
        action="append",
        default=[],
        metavar="APP|BACKEND[,APP|BACKEND...]",
        help=(
            "Refine only the listed kernel types. Separate multiple exact "
            "APP|BACKEND values with commas or repeat this option. By default "
            "all kernel types are refined."
        ),
    )
    refine.add_argument(
        "--sampling-strategy",
        choices=("midpoint", "random"),
        default="midpoint",
        help="Choose bracketed adaptive midpoint sampling or the legacy seeded shuffle.",
    )
    refine.add_argument("--seed", type=int, default=0)
    refine.add_argument("--metric", default="p50_us")
    refine.add_argument(
        "--require-convergence",
        action="store_true",
        help=(
            "Return a nonzero downstream gate result for budget-exhausted or "
            "unbracketed outcomes without launching additional probes."
        ),
    )
