#!/usr/bin/env python3
"""Sensitivity check for vector-kernel latency in prepared latency results.

This intentionally avoids pandas so it can run in the same lightweight shell
environment used for quick debug checks. It uses the total.csv files emitted by
prepare.py:

  main_all/total.csv           total model latency
  main_all_gemm_only/total.csv GEMM-only latency

Vector latency is derived as total - GEMM-only. The script then scales that
vector slice and reranks C1/C2/C3/C4.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


C4_ALONE_VARIANT = "all_fpint_gemm_improve_alone_layout_spinquant"
C4_FUSED_VARIANT = "all_fpint_gemm_improve_fused_layout_spinquant"

VARIANT_LABELS = {
    "all_sgemm_tcu_spinquant": "C1",
    "attn_sgemm_tcu_fpint_gemm_naive_spinquant": "C2",
    "all_fpint_gemm_naive_spinquant": "C3",
    C4_FUSED_VARIANT: "C4",
    C4_ALONE_VARIANT: "C4-alone",
}

PREPARE_PY_SHAPES = {
    ("prefill", 1, 1024),
    ("prefill", 1, 2048),
    ("generation", 1, 1024),
    ("generation", 1, 2048),
    ("generation", 2, 1024),
    ("generation", 2, 2048),
}

EXPECTED_LABELS = ("C1", "C2", "C3", "C4")


@dataclass(frozen=True, order=True)
class Shape:
    stage: str
    batch: int
    seq_len: int


@dataclass(frozen=True)
class CandidateResult:
    shape: Shape
    label: str
    total_us: float
    gemm_us: float
    vector_us: float
    adjusted_us: float


def _float(value: str, *, column: str, path: Path) -> float:
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"bad numeric value for {column!r} in {path}: {value!r}") from exc


def _int(value: str, *, column: str, path: Path) -> int:
    return int(_float(value, column=column, path=path))


def _latency_column(fieldnames: Iterable[str] | None, metric: str) -> str:
    fields = set(fieldnames or ())
    if metric == "fpga_cycle":
        if "final_total_fpga_cycles" in fields:
            return "final_total_fpga_cycles"
        if "final_total_metric_value" in fields:
            return "final_total_metric_value"
    if "final_total_latency_us" in fields:
        return "final_total_latency_us"
    if "total_latency_us" in fields:
        return "total_latency_us"
    raise ValueError("total CSV does not contain a usable latency column")


def read_total_csv(path: Path, *, metric: str) -> dict[tuple[Shape, str], float]:
    if not path.exists():
        raise FileNotFoundError(path)

    results: dict[tuple[Shape, str], float] = {}
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        value_column = _latency_column(reader.fieldnames, metric)
        for row in reader:
            if row.get("metric") and row["metric"] != metric:
                continue
            variant = row.get("variant", "")
            label = VARIANT_LABELS.get(variant)
            if label is None or label == "C4-alone":
                continue
            shape = Shape(
                stage=row["stage"],
                batch=_int(row["batch"], column="batch", path=path),
                seq_len=_int(row["seq_len"], column="seq_len", path=path),
            )
            results[(shape, label)] = _float(row[value_column], column=value_column, path=path)
    return results


def raw_db_stats(run_root: Path) -> list[tuple[Path, int, int]]:
    stats: list[tuple[Path, int, int]] = []
    for path in sorted(run_root.glob("*/raw_db.csv")):
        with path.open(newline="") as f:
            reader = csv.DictReader(f)
            rows = 0
            pass_rows = 0
            for row in reader:
                rows += 1
                if row.get("status") == "pass":
                    pass_rows += 1
            stats.append((path, rows, pass_rows))
    return stats


def build_results(
    total: dict[tuple[Shape, str], float],
    gemm: dict[tuple[Shape, str], float],
    *,
    vector_scale: float,
    all_shapes: bool,
) -> list[CandidateResult]:
    results: list[CandidateResult] = []
    for (shape, label), total_us in sorted(total.items(), key=lambda item: (item[0][0].stage, item[0][0].batch, item[0][0].seq_len, item[0][1])):
        if not all_shapes and (shape.stage, shape.batch, shape.seq_len) not in PREPARE_PY_SHAPES:
            continue
        gemm_us = gemm.get((shape, label), 0.0)
        vector_us = total_us - gemm_us
        if vector_us < -1e-6:
            raise ValueError(
                f"GEMM-only latency exceeds total latency for {shape} {label}: "
                f"gemm={gemm_us}, total={total_us}"
            )
        vector_us = max(vector_us, 0.0)
        adjusted_us = gemm_us + vector_scale * vector_us
        results.append(CandidateResult(shape, label, total_us, gemm_us, vector_us, adjusted_us))
    return results


def group_by_shape(results: Iterable[CandidateResult]) -> dict[Shape, list[CandidateResult]]:
    groups: dict[Shape, list[CandidateResult]] = {}
    for result in results:
        groups.setdefault(result.shape, []).append(result)
    return groups


def seconds(us: float) -> float:
    return us / 1_000_000.0


def print_summary(results: list[CandidateResult], *, vector_scale: float) -> bool:
    groups = group_by_shape(results)
    c4_wins_all = True
    print(f"vector_scale={vector_scale:g}")
    print("shape,baseline_order,adjusted_order,c4_status,c4_adjusted_s,best_adjusted_s,c4_gap_pct")
    for shape in sorted(groups):
        rows = groups[shape]
        labels = {row.label for row in rows}
        if not all(label in labels for label in EXPECTED_LABELS):
            missing = ",".join(label for label in EXPECTED_LABELS if label not in labels)
            print(f"# skip {shape.stage} batch={shape.batch} seq={shape.seq_len}: missing {missing}")
            continue

        baseline_order = sorted(rows, key=lambda row: row.total_us)
        adjusted_order = sorted(rows, key=lambda row: row.adjusted_us)
        best = adjusted_order[0]
        c4 = next(row for row in rows if row.label == "C4")
        c4_wins = best.label == "C4"
        c4_wins_all &= c4_wins
        if c4_wins and len(adjusted_order) > 1:
            next_best = adjusted_order[1]
            gap_pct = (next_best.adjusted_us - c4.adjusted_us) / next_best.adjusted_us * 100.0
            status = "C4_best"
        else:
            gap_pct = (c4.adjusted_us - best.adjusted_us) / best.adjusted_us * 100.0
            status = f"C4_loses_to_{best.label}"

        baseline_text = " ".join(f"{row.label}:{seconds(row.total_us):.3f}s" for row in baseline_order)
        adjusted_text = " ".join(f"{row.label}:{seconds(row.adjusted_us):.3f}s" for row in adjusted_order)
        print(
            f"{shape.stage}/b{shape.batch}/s{shape.seq_len},"
            f"{baseline_text},"
            f"{adjusted_text},"
            f"{status},"
            f"{seconds(c4.adjusted_us):.3f},"
            f"{seconds(best.adjusted_us):.3f},"
            f"{gap_pct:.2f}"
        )
    return c4_wins_all


def print_component_breakdown(results: list[CandidateResult]) -> None:
    print()
    print("component_breakdown")
    print("shape,label,total_s,gemm_s,vector_s,vector_fraction,adjusted_s")
    for result in sorted(results, key=lambda row: (row.shape.stage, row.shape.batch, row.shape.seq_len, row.label)):
        vector_fraction = result.vector_us / result.total_us if result.total_us else 0.0
        print(
            f"{result.shape.stage}/b{result.shape.batch}/s{result.shape.seq_len},"
            f"{result.label},"
            f"{seconds(result.total_us):.3f},"
            f"{seconds(result.gemm_us):.3f},"
            f"{seconds(result.vector_us):.3f},"
            f"{vector_fraction:.4f},"
            f"{seconds(result.adjusted_us):.3f}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-root",
        type=Path,
        default=Path("analysis_workspace/latency_on_hw/outputs_main.2026.06.29"),
        help="Run output directory containing raw DB subdirectories and figures_notebook.",
    )
    parser.add_argument("--vector-scale", type=float, default=1.8)
    parser.add_argument("--metric", default="p50_us")
    parser.add_argument(
        "--all-shapes",
        action="store_true",
        help="Analyze all prepared notebook shapes instead of the target shapes in prepare.py.",
    )
    parser.add_argument(
        "--no-breakdown",
        action="store_true",
        help="Only print rank summary.",
    )
    parser.add_argument(
        "--fail-on-c4-loss",
        action="store_true",
        help="Return exit code 2 if C4 is not best for every analyzed shape.",
    )
    args = parser.parse_args()

    raw_stats = raw_db_stats(args.run_root)
    if not raw_stats:
        raise FileNotFoundError(f"no */raw_db.csv files found under {args.run_root}")

    print("raw_db_inputs")
    for path, rows, pass_rows in raw_stats:
        print(f"{path}: rows={rows} pass_rows={pass_rows}")
    print()

    figure_root = args.run_root / "figures_notebook"
    total = read_total_csv(figure_root / "main_all" / "total.csv", metric=args.metric)
    gemm = read_total_csv(figure_root / "main_all_gemm_only" / "total.csv", metric=args.metric)
    results = build_results(total, gemm, vector_scale=args.vector_scale, all_shapes=args.all_shapes)
    if not results:
        raise RuntimeError("no matching result rows found")

    c4_wins_all = print_summary(results, vector_scale=args.vector_scale)
    if not args.no_breakdown:
        print_component_breakdown(results)

    if args.fail_on_c4_loss and not c4_wins_all:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
