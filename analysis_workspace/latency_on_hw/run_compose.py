#!/usr/bin/env python3
"""Compose Llama2-7B and Llama3-8B hardware latency results.

Usage from the repository root::

    conda run -n vortex python analysis_workspace/latency_on_hw/run_compose.py \
      --llama2-results analysis_workspace/latency_on_hw/outputs_llama2_main \
      --llama3-results analysis_workspace/latency_on_hw/outputs_llama3_main \
      --out analysis_workspace/latency_on_hw/composed_results

The target workloads come from the suites most recently written by
``make_case.sh`` under ``generated_suites/llama2_7b_main`` and
``generated_suites/llama3_8b_main``. Pass ``--llama2-suites`` or
``--llama3-suites`` when those generated directories live elsewhere.

The result roots must contain ``C1/raw_db.csv``, ``C3/raw_db.csv``, and
``C4/raw_db.csv``. By default the script composes cycle-derived latency using
the ``fpga_cycle_latency`` metric (microseconds) while preserving the original
``fpga_cycle`` count and resolved ``fpga_period_s`` in the composed output.
latest passing measurement, rejects unresolved latency or power, and infers
warmup and iteration values from the input raw DBs. Use ``--metric``,
``--select``, ``--missing``, ``--warmup``, or ``--iterations`` to override
the compose selection defaults; the final complete-output validation always
remains enabled.

Outputs are written under ``OUT/llama2_7b``, ``OUT/llama3_8b``, and
``OUT/combined``. Each model directory contains ``composed.csv``,
``summary.csv``, and ``manifest.json``.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import pandas as pd
import yaml


def find_repo_root(start: Path | None = None) -> Path:
    path = Path.cwd() if start is None else start
    for candidate in (path.resolve(), *path.resolve().parents):
        if (candidate / "tools" / "latency_bench").is_dir():
            return candidate
    raise RuntimeError("failed to find Vortex repository root")


REPO_ROOT = find_repo_root()
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.latency_bench.compose import (  # noqa: E402
    ComposeOptions,
    METRIC_COLUMNS,
    MISSING_POLICIES,
    SELECT_POLICIES,
    compose_latency,
    write_compose_outputs,
)
from tools.latency_bench.suite import find_repo_root as find_suite_repo_root  # noqa: E402
from tools.latency_bench.suite import load_suite  # noqa: E402


LATENCY_DIR = REPO_ROOT / "analysis_workspace" / "latency_on_hw"
DEFAULT_RAW_DB_SUBDIRS = ("C1", "C3", "C4")
GENERATED_SUITE_STAGES = ("prefill", "generation")
REQUIRED_POWER_COLUMNS = (
    "power_avg_w",
    "power_vcc_avg_w",
    "power_dynamic_avg_w",
)


@dataclass(frozen=True)
class ModelInput:
    key: str
    suite_dir: Path
    results_root: Path


def _csv_names(value: str) -> tuple[str, ...]:
    names = tuple(item.strip() for item in value.split(",") if item.strip())
    if not names:
        raise argparse.ArgumentTypeError("expected at least one comma-separated name")
    return names


def _suite_paths(model: ModelInput) -> tuple[Path, ...]:
    paths: list[Path] = []
    for stage in GENERATED_SUITE_STAGES:
        index_paths = sorted(model.suite_dir.glob(f"*_{stage}/index.yaml"))
        if not index_paths:
            raise FileNotFoundError(
                f"missing {model.key} generated {stage} suite indexes under "
                f"{model.suite_dir}"
            )
        for index_path in index_paths:
            payload = yaml.safe_load(index_path.read_text()) or {}
            generated = payload.get("generated") or []
            if not isinstance(generated, list) or not generated:
                raise ValueError(f"generated suite index has no entries: {index_path}")
            for entry in generated:
                if not isinstance(entry, dict) or not entry.get("suite"):
                    raise ValueError(
                        f"invalid generated suite entry in {index_path}: {entry!r}"
                    )
                indexed_path = Path(str(entry["suite"])).expanduser()
                local_path = index_path.parent / indexed_path.name
                path = (
                    local_path
                    if local_path.is_file()
                    else indexed_path
                )
                paths.append(path)
    if len(paths) != len(set(paths)):
        raise ValueError(f"duplicate generated suite paths under {model.suite_dir}")
    return tuple(paths)


def _raw_db_paths(
    model: ModelInput,
    raw_db_subdirs: tuple[str, ...],
) -> tuple[Path, ...]:
    return tuple(
        model.results_root / subdir / "raw_db.csv"
        for subdir in raw_db_subdirs
    )


def _require_files(paths: tuple[Path, ...], label: str) -> None:
    missing = [path for path in paths if not path.is_file()]
    if missing:
        lines = "\n".join(f"  {path}" for path in missing)
        raise FileNotFoundError(f"missing {label} file(s):\n{lines}")


def _measurement_overrides(
    raw_dbs: tuple[Path, ...],
    *,
    warmup: int | None,
    iterations: int | None,
) -> tuple[int | None, int | None]:
    if warmup is not None and iterations is not None:
        return warmup, iterations
    frames = [
        pd.read_csv(path, usecols=["warmup", "iterations", "status"])
        for path in raw_dbs
    ]
    raw = pd.concat(frames, ignore_index=True)
    passed = raw[raw["status"].astype(str) == "pass"].copy()
    if passed.empty:
        return warmup, iterations
    pairs = (
        passed.groupby(["warmup", "iterations"], dropna=True)
        .size()
        .sort_values(ascending=False)
    )
    inferred_warmup, inferred_iterations = pairs.index[0]
    return (
        int(inferred_warmup) if warmup is None else warmup,
        int(inferred_iterations) if iterations is None else iterations,
    )


def _positive_int_values(frame: pd.DataFrame, column: str) -> list[int]:
    if column not in frame.columns:
        return []
    values = pd.to_numeric(frame[column], errors="coerce").dropna().astype(int)
    return sorted({int(value) for value in values if int(value) > 0})


def _count_summary(frame: pd.DataFrame, column: str) -> str:
    if column not in frame.columns:
        return "n/a"
    counts = frame[column].astype(str).value_counts(dropna=False, sort=False)
    return ",".join(f"{value}:{int(count)}" for value, count in counts.items())


def _validate_complete_composed(frame: pd.DataFrame, *, label: str) -> dict[str, object]:
    required = {
        "model",
        "case_id",
        "stage",
        "batch",
        "prefill_seq_len",
        "gen_kv_len",
        "out_tokens",
        "output_token_index",
        "calls_per_forward",
        "fpga_cycle",
        "fpga_cycle_latency",
        "fpga_period_s",
        "latency_us",
        "compose_status",
        "latency_resolution_kind",
        "power_resolution_kind",
        *REQUIRED_POWER_COLUMNS,
    }
    missing_columns = sorted(required - set(frame.columns))
    if missing_columns:
        raise ValueError(
            f"{label} composed output is missing required columns: "
            f"{', '.join(missing_columns)}"
        )

    duplicated = frame.duplicated(["model", "case_id"], keep=False)
    if bool(duplicated.any()):
        duplicate_ids = (
            frame.loc[duplicated, ["model", "case_id"]]
            .astype(str)
            .agg(":".join, axis=1)
            .drop_duplicates()
            .tolist()
        )
        preview = ", ".join(duplicate_ids[:10])
        suffix = "" if len(duplicate_ids) <= 10 else f", ... ({len(duplicate_ids)} total)"
        raise ValueError(f"{label} composed output has duplicate logical cases: {preview}{suffix}")

    valid_status = frame["compose_status"].astype(str).isin({"pass", "estimated"})
    latency = pd.to_numeric(frame["latency_us"], errors="coerce")
    missing_latency = ~valid_status | latency.isna()
    for column in ("fpga_cycle", "fpga_cycle_latency", "fpga_period_s"):
        missing_latency |= pd.to_numeric(frame[column], errors="coerce").isna()
    cycle_rows = frame["metric"].astype(str).eq("fpga_cycle_latency")
    if bool(cycle_rows.any()):
        cycles = pd.to_numeric(frame["fpga_cycle"], errors="coerce")
        periods = pd.to_numeric(frame["fpga_period_s"], errors="coerce")
        cycle_latency = pd.to_numeric(
            frame["fpga_cycle_latency"], errors="coerce"
        )
        expected_latency = cycles * periods * 1_000_000.0
        tolerance = expected_latency.abs().clip(lower=1.0) * 1e-9
        inconsistent = cycle_rows & (
            (cycle_latency - expected_latency).abs() > tolerance
        )
        inconsistent |= cycle_rows & ((latency - cycle_latency).abs() > tolerance)
        if bool(inconsistent.any()):
            ids = frame.loc[inconsistent, "case_id"].astype(str).tolist()
            raise ValueError(
                f"{label} composed output has inconsistent cycle latency: "
                f"{ids[:10]} ({len(ids)} total)"
            )
    missing_power = pd.Series(False, index=frame.index)
    for column in REQUIRED_POWER_COLUMNS:
        missing_power |= pd.to_numeric(frame[column], errors="coerce").isna()

    if bool(missing_latency.any()) or bool(missing_power.any()):
        bad = frame.loc[missing_latency | missing_power, ["model", "case_id"]].copy()
        bad["missing_latency"] = missing_latency.loc[bad.index]
        bad["missing_power"] = missing_power.loc[bad.index]
        preview = ", ".join(
            f"{row.model}:{row.case_id}"
            f"(latency={bool(row.missing_latency)},power={bool(row.missing_power)})"
            for row in bad.head(10).itertuples()
        )
        suffix = "" if len(bad) <= 10 else f", ... ({len(bad)} total)"
        raise ValueError(f"{label} composed output is incomplete: {preview}{suffix}")

    generation = frame[frame["stage"].astype(str).eq("generation")]
    return {
        "complete": True,
        "duplicate_case_count": 0,
        "missing_latency_count": 0,
        "missing_power_count": 0,
        "generation_out_tokens": _positive_int_values(generation, "out_tokens"),
    }


def compose_model(
    model: ModelInput,
    *,
    raw_db_subdirs: tuple[str, ...],
    out_root: Path,
    metric: str,
    select: str,
    missing: str,
    warmup: int | None,
    iterations: int | None,
) -> tuple[pd.DataFrame, dict[str, object]]:
    model_started = time.monotonic()
    suite_paths = _suite_paths(model)
    raw_dbs = _raw_db_paths(model, raw_db_subdirs)
    _require_files(suite_paths, f"{model.key} suite")
    _require_files(raw_dbs, f"{model.key} raw DB")
    print(
        f"[compose] {model.key}: suites={len(suite_paths)} raw_dbs={len(raw_dbs)} "
        "resolving measurement settings",
        flush=True,
    )
    warmup_override, iterations_override = _measurement_overrides(
        raw_dbs,
        warmup=warmup,
        iterations=iterations,
    )
    print(
        f"[compose] {model.key}: metric={metric} select={select} "
        f"warmup={warmup_override} iterations={iterations_override}",
        flush=True,
    )

    frames: list[pd.DataFrame] = []
    repo_root = find_suite_repo_root(REPO_ROOT)
    for suite_index, suite_path in enumerate(suite_paths, start=1):
        suite_started = time.monotonic()
        suite = load_suite(
            suite_path,
            repo_root=repo_root,
            warmup_override=warmup_override,
            iterations_override=iterations_override,
        )
        print(
            f"[compose] {model.key} {suite_index}/{len(suite_paths)} "
            f"{suite.name}: cases={len(suite.cases)}",
            flush=True,
        )
        composed = compose_latency(
            suite,
            ComposeOptions(
                raw_dbs=raw_dbs,
                out=out_root / model.key,
                metric=metric,
                select=select,
                missing=missing,
            ),
        )
        composed["model"] = model.key
        model_column = composed.pop("model")
        composed.insert(0, "model", model_column)
        composed.insert(1, "suite_file", str(suite_path))
        frames.append(composed)
        print(
            f"[compose] {model.key} {suite_index}/{len(suite_paths)} done: "
            f"rows={len(composed)} status={_count_summary(composed, 'compose_status')} "
            f"elapsed={time.monotonic() - suite_started:.1f}s",
            flush=True,
        )

    combined = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
    completeness = _validate_complete_composed(combined, label=model.key)
    model_out = out_root / model.key
    composed_path, summary_path = write_compose_outputs(combined, model_out)
    manifest = {
        "model": model.key,
        "suite_dir": str(model.suite_dir.resolve()),
        "results_root": str(model.results_root.resolve()),
        "suite_files": [str(path.resolve()) for path in suite_paths],
        "raw_dbs": [str(path.resolve()) for path in raw_dbs],
        "metric": metric,
        "select": select,
        "missing": missing,
        "warmup_override": warmup_override,
        "iterations_override": iterations_override,
        "row_count": len(combined),
        "compose_status_counts": (
            combined["compose_status"].value_counts(dropna=False).to_dict()
            if "compose_status" in combined else {}
        ),
        "latency_resolution_counts": (
            combined["latency_resolution_kind"].value_counts(dropna=False).to_dict()
            if "latency_resolution_kind" in combined else {}
        ),
        "power_resolution_counts": (
            combined["power_resolution_kind"].value_counts(dropna=False).to_dict()
            if "power_resolution_kind" in combined else {}
        ),
        "completeness": completeness,
        "composed_csv": str(composed_path.resolve()),
        "summary_csv": str(summary_path.resolve()) if summary_path else "",
    }
    (model_out / "manifest.json").write_text(
        json.dumps(manifest, indent=2, default=str) + "\n"
    )
    print(
        f"[compose] {model.key}: complete rows={len(combined)} "
        f"elapsed={time.monotonic() - model_started:.1f}s",
        flush=True,
    )
    return combined, manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Compose Llama2-7B and Llama3-8B latency benchmark result folders "
            "against the suites generated by make_case.sh."
        )
    )
    parser.add_argument("--llama2-results", required=True, type=Path)
    parser.add_argument("--llama3-results", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument(
        "--generated-suite-root",
        "--suite-root",
        dest="generated_suite_root",
        type=Path,
        default=LATENCY_DIR / "generated_suites",
        help=(
            "Directory containing generated llama2_7b_main/ and "
            "llama3_8b_main/ suite folders. --suite-root is a compatibility alias."
        ),
    )
    parser.add_argument(
        "--llama2-suites",
        type=Path,
        default=None,
        help="Generated Llama2 suite directory; defaults to GENERATED_SUITE_ROOT/llama2_7b_main.",
    )
    parser.add_argument(
        "--llama3-suites",
        type=Path,
        default=None,
        help="Generated Llama3 suite directory; defaults to GENERATED_SUITE_ROOT/llama3_8b_main.",
    )
    parser.add_argument(
        "--raw-db-subdirs",
        type=_csv_names,
        default=DEFAULT_RAW_DB_SUBDIRS,
        help="Comma-separated result subdirectories containing raw_db.csv.",
    )
    parser.add_argument(
        "--metric", choices=METRIC_COLUMNS, default="fpga_cycle_latency"
    )
    parser.add_argument("--select", choices=SELECT_POLICIES, default="latest")
    parser.add_argument("--missing", choices=MISSING_POLICIES, default="error")
    parser.add_argument(
        "--warmup",
        type=int,
        default=None,
        help="Suite warmup override; default infers the most common passing raw DB value.",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=None,
        help="Suite iteration override; default infers the most common passing raw DB value.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    started = time.monotonic()
    args = build_parser().parse_args(argv)
    models = (
        ModelInput(
            "llama2_7b",
            args.llama2_suites or args.generated_suite_root / "llama2_7b_main",
            args.llama2_results,
        ),
        ModelInput(
            "llama3_8b",
            args.llama3_suites or args.generated_suite_root / "llama3_8b_main",
            args.llama3_results,
        ),
    )
    args.out.mkdir(parents=True, exist_ok=True)

    frames = []
    manifests = []
    for model in models:
        composed, manifest = compose_model(
            model,
            raw_db_subdirs=args.raw_db_subdirs,
            out_root=args.out,
            metric=args.metric,
            select=args.select,
            missing=args.missing,
            warmup=args.warmup,
            iterations=args.iterations,
        )
        frames.append(composed)
        manifests.append(manifest)
        print(
            f"{model.key}: wrote {args.out / model.key / 'composed.csv'} "
            f"({len(composed)} rows)",
            flush=True,
        )

    combined = pd.concat(frames, ignore_index=True)
    combined_completeness = _validate_complete_composed(combined, label="combined")
    composed_path, summary_path = write_compose_outputs(combined, args.out / "combined")
    top_manifest = {
        "models": manifests,
        "metric": args.metric,
        "select": args.select,
        "missing": args.missing,
        "row_count": len(combined),
        "completeness": combined_completeness,
        "composed_csv": str(composed_path.resolve()),
        "summary_csv": str(summary_path.resolve()) if summary_path else "",
    }
    (args.out / "manifest.json").write_text(
        json.dumps(top_manifest, indent=2, default=str) + "\n"
    )
    print(
        f"combined: wrote {composed_path} ({len(combined)} rows, "
        f"{time.monotonic() - started:.1f}s total)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
