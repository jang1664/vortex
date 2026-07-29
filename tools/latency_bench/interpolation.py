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
    suite_to_expanded_yaml,
    suite_to_rows,
)
from .yaml_io import safe_dump


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


_DYNAMIC_SHAPE_KEYS = {
    "K", "N", "seqk", "cache_len", "logical_cache_length",
    "logical_kv_start", "logical_kv_end", "padded_cache_length",
    "output_token_index", "offset", "cache_position",
    "decode_sample_weight", "measurement_kind",
    "interpolation_lower_step", "interpolation_upper_step",
    "interpolation_upper_ratio", "reuse_representative_step",
}


def kernel_type(case: BenchCase) -> str:
    return "|".join((case.app, case.backend, case.variant, case.name))


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
            except ValueError:
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
) -> None:
    rows = suite_to_rows(refined_suite(suite, raw_db, metric))
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


def promote_probe_rows(main_raw_db: Path, probe_raw_db: Path, exec_keys: set[str]) -> int:
    _, probe_rows = _raw_metric(probe_raw_db, "p50_us")
    existing_values, _ = _raw_metric(main_raw_db, "p50_us")
    rows = []
    added = 0
    for key in sorted(exec_keys):
        if key in existing_values or key not in probe_rows:
            continue
        row = {column: probe_rows[key].get(column, "") for column in RAW_DB_COLUMNS}
        row["run_id"] = "interpolation_refine"
        rows.append(row)
        added += 1
    _write_raw_rows(
        rows, main_raw_db, mode="upsert", run_id="interpolation_refine"
    )
    return added


def p95(errors: list[InterpolationError]) -> float:
    if not errors:
        return math.inf
    values = sorted(error.relative_error for error in errors)
    return values[min(len(values) - 1, math.ceil(0.95 * len(values)) - 1)]


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
    history: list[dict[str, Any]],
    status: str,
) -> None:
    iteration_columns = [
        "kernel_type",
        "iteration",
        "validation_samples",
        "p95_relative_error",
        "target_error",
        "status",
        "promoted_measurements",
    ]
    pd.DataFrame(history, columns=iteration_columns).to_csv(
        out / "iterations.csv", index=False
    )
    write_current_cases(suite, main_raw, out / "cases.csv", args.metric)
    (out / "state.json").write_text(json.dumps({
        "suite": str(Path(args.suite).resolve()),
        "output_root": str(output_root.resolve()),
        "raw_db": str(main_raw.resolve()),
        "probe_raw_db": str(probe_raw.resolve()) if probe_raw else "",
        "target_error": args.target_error,
        "max_iterations": args.max_iterations,
        "seed": args.seed,
        "kernel_types": len(grouped),
        "initial_unresolved_cases": len(unresolved),
        "remaining_unresolved_cases": len(
            unresolved_interpolation_candidates(suite, main_raw, args.metric)
        ),
        "promoted_measurements": sum(
            int(item.get("promoted_measurements", 0)) for item in history
        ),
        "status": status,
    }, indent=2) + "\n")
    publish_latest(
        out,
        output_root,
        "refinement",
        ["iterations.csv", "state.json"],
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
                    raw_db, partial_raw, {case.exec_key for case in selected}
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
            raw_db, probe_raw_db, {case.exec_key for case in selected}
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
    output_root, out = _artifact_dir(
        args, "refinements", args.refinement_id
    )
    main_raw = _main_raw_db(args, output_root)
    suite = _load_suite_for_raw(Path(args.suite), main_raw)
    probe_raw = Path(args.probe_raw_db) if args.probe_raw_db else None
    out.mkdir(parents=True, exist_ok=True)
    grouped: dict[str, list[BenchCase]] = defaultdict(list)
    unresolved = unresolved_interpolation_candidates(suite, main_raw, args.metric)
    for case in unresolved:
        grouped[kernel_type(case)].append(case)
    if grouped and not args.probe_raw_db and not args.measure_command:
        raise ValueError("refine requires --probe-raw-db or --measure-command")
    rng = random.Random(args.seed)
    history = []
    write_refinement_progress(
        suite=suite,
        main_raw=main_raw,
        probe_raw=probe_raw,
        output_root=output_root,
        out=out,
        args=args,
        grouped=grouped,
        unresolved=unresolved,
        history=history,
        status="no_candidates" if not unresolved else "running",
    )
    for key in sorted(grouped):
        remaining = list(grouped[key])
        rng.shuffle(remaining)
        for iteration in range(args.max_iterations):
            validation = remaining[:args.validation_samples]
            remaining = remaining[args.validation_samples:]
            if not validation:
                break
            if args.measure_command:
                validation_suite = out / f"validate_{len(history):04d}.yaml"
                write_candidate_suite(suite, validation, validation_suite)
                validation_run = out / "validation_run"
                try:
                    probe_raw = run_measurement_command(
                        args.measure_command, validation_suite, validation_run
                    )
                except (KeyboardInterrupt, subprocess.CalledProcessError):
                    partial_raw = validation_run / "raw_db.csv"
                    partial_errors = (
                        evaluate_cases(
                            suite, validation, main_raw, partial_raw, args.metric
                        )
                        if partial_raw.exists() else []
                    )
                    added = (
                        promote_probe_rows(
                            main_raw,
                            partial_raw,
                            {case.exec_key for case in validation},
                        )
                        if partial_raw.exists() else 0
                    )
                    history.append({
                        "kernel_type": key,
                        "iteration": iteration,
                        "validation_samples": len(partial_errors),
                        "p95_relative_error": p95(partial_errors),
                        "target_error": args.target_error,
                        "status": "interrupted",
                        "promoted_measurements": added,
                    })
                    write_refinement_progress(
                        suite=suite,
                        main_raw=main_raw,
                        probe_raw=partial_raw if partial_raw.exists() else None,
                        output_root=output_root,
                        out=out,
                        args=args,
                        grouped=grouped,
                        unresolved=unresolved,
                        history=history,
                        status="interrupted",
                    )
                    raise
            assert probe_raw is not None
            errors = evaluate_cases(suite, validation, main_raw, probe_raw, args.metric)
            current_p95 = p95(errors)
            added = promote_probe_rows(
                main_raw, probe_raw, {case.exec_key for case in validation}
            )
            history.append({
                "kernel_type": key,
                "iteration": iteration,
                "validation_samples": len(errors),
                "p95_relative_error": current_p95,
                "target_error": args.target_error,
                "status": "converged" if current_p95 <= args.target_error else "refining",
                "promoted_measurements": added,
            })
            write_refinement_progress(
                suite=suite,
                main_raw=main_raw,
                probe_raw=probe_raw,
                output_root=output_root,
                out=out,
                args=args,
                grouped=grouped,
                unresolved=unresolved,
                history=history,
                status="running",
            )
            if current_p95 <= args.target_error:
                break
            if not errors:
                history[-1]["status"] = "exhausted"
                break
    write_refinement_progress(
        suite=suite,
        main_raw=main_raw,
        probe_raw=probe_raw,
        output_root=output_root,
        out=out,
        args=args,
        grouped=grouped,
        unresolved=unresolved,
        history=history,
        status="no_candidates" if not unresolved else "completed",
    )
    if unresolved:
        print(f"refined {len(grouped)} kernel types; wrote {out / 'iterations.csv'}")
    else:
        print("no unresolved interpolation cases; nothing to refine")
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
    refine.add_argument("--seed", type=int, default=0)
    refine.add_argument("--metric", default="p50_us")
