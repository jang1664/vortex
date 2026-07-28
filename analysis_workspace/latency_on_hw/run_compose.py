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
``C4/raw_db.csv``. By default the script composes ``fpga_cycle`` using the
latest passing measurement, keeps unresolved cases as NaN, and infers warmup
and iteration values from the input raw DBs. Use ``--metric``, ``--select``,
``--missing``, ``--warmup``, or ``--iterations`` to override those defaults.

Outputs are written under ``OUT/llama2_7b``, ``OUT/llama3_8b``, and
``OUT/combined``. Each model directory contains ``composed.csv``,
``summary.csv``, and ``manifest.json``.
"""

from __future__ import annotations

import argparse
import json
import sys
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
    suite_paths = _suite_paths(model)
    raw_dbs = _raw_db_paths(model, raw_db_subdirs)
    _require_files(suite_paths, f"{model.key} suite")
    _require_files(raw_dbs, f"{model.key} raw DB")
    warmup_override, iterations_override = _measurement_overrides(
        raw_dbs,
        warmup=warmup,
        iterations=iterations,
    )

    frames: list[pd.DataFrame] = []
    repo_root = find_suite_repo_root(REPO_ROOT)
    for suite_path in suite_paths:
        suite = load_suite(
            suite_path,
            repo_root=repo_root,
            warmup_override=warmup_override,
            iterations_override=iterations_override,
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

    combined = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
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
        "composed_csv": str(composed_path.resolve()),
        "summary_csv": str(summary_path.resolve()) if summary_path else "",
    }
    (model_out / "manifest.json").write_text(
        json.dumps(manifest, indent=2, default=str) + "\n"
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
    parser.add_argument("--metric", choices=METRIC_COLUMNS, default="fpga_cycle")
    parser.add_argument("--select", choices=SELECT_POLICIES, default="latest")
    parser.add_argument("--missing", choices=MISSING_POLICIES, default="nan")
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
            f"({len(composed)} rows)"
        )

    combined = pd.concat(frames, ignore_index=True)
    composed_path, summary_path = write_compose_outputs(combined, args.out / "combined")
    top_manifest = {
        "models": manifests,
        "metric": args.metric,
        "select": args.select,
        "missing": args.missing,
        "row_count": len(combined),
        "composed_csv": str(composed_path.resolve()),
        "summary_csv": str(summary_path.resolve()) if summary_path else "",
    }
    (args.out / "manifest.json").write_text(
        json.dumps(top_manifest, indent=2, default=str) + "\n"
    )
    print(f"combined: wrote {composed_path} ({len(combined)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
