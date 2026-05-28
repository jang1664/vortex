from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from .report import build_summary


METRIC_COLUMNS = {
    "avg": ("weighted_total_avg_us", "weighted_avg_us"),
    "p50": ("weighted_total_p50_us", "weighted_p50_us"),
    "p95": ("weighted_total_p95_us", "weighted_p95_us"),
}

PALETTE = [
    "#2f6f73", "#9a5b2f", "#4a677d", "#b24b44", "#6c7a34", "#725a8f",
    "#c4872f", "#477f5e", "#8a4f66", "#3b6d9b", "#9d6b48", "#5f7f91",
    "#7d6040", "#56806f", "#a15b37", "#65737e", "#846c5b", "#4f6f52",
    "#8f6f3a", "#6d5f7d", "#b06f50", "#4f7d8a", "#7f664f", "#5c735c",
]


@dataclass(frozen=True)
class CandidateInput:
    label: str
    path: Path


def parse_candidate_spec(value: str) -> CandidateInput:
    if "=" not in value:
        raise ValueError(f"candidate must be LABEL=PATH: {value}")
    label, raw_path = value.split("=", 1)
    label = label.strip()
    raw_path = raw_path.strip()
    if not label or not raw_path:
        raise ValueError(f"candidate must be LABEL=PATH: {value}")
    return CandidateInput(label=label, path=Path(raw_path))


def _metric_column(summary: pd.DataFrame, metric: str) -> str:
    for column in METRIC_COLUMNS[metric]:
        if column in summary.columns:
            return column
    raise ValueError(f"summary is missing weighted columns for metric={metric}")


def _resolve_candidate_paths(path: Path) -> tuple[Path | None, Path | None, Path]:
    path = path.resolve()
    if path.is_dir():
        return path / "results.csv", path / "summary.csv", path
    if path.name == "results.csv":
        return path, path.parent / "summary.csv", path.parent
    if path.name == "summary.csv":
        results = path.parent / "results.csv"
        return results if results.exists() else None, path, path.parent
    raise ValueError(f"candidate path must be a run directory, results.csv, or summary.csv: {path}")


def _read_candidate(candidate: CandidateInput, order: int) -> tuple[pd.DataFrame | None, pd.DataFrame]:
    results_path, summary_path, run_dir = _resolve_candidate_paths(candidate.path)
    results: pd.DataFrame | None = None
    if results_path and results_path.exists():
        results = pd.read_csv(results_path)

    if summary_path and summary_path.exists():
        summary = pd.read_csv(summary_path)
    elif results is not None:
        summary = build_summary(results)
    else:
        raise FileNotFoundError(f"no results.csv or summary.csv found for candidate {candidate.label}: {candidate.path}")

    def add_metadata(df: pd.DataFrame, source_csv: Path | None) -> pd.DataFrame:
        out = df.copy()
        out.insert(0, "candidate_order", order)
        out.insert(1, "candidate", candidate.label)
        out.insert(2, "run_dir", str(run_dir))
        out.insert(3, "source_csv", str(source_csv) if source_csv else "")
        return out

    results_out = add_metadata(results, results_path) if results is not None else None
    summary_out = add_metadata(summary, summary_path if summary_path and summary_path.exists() else results_path)
    return results_out, summary_out


def load_candidates(candidates: list[CandidateInput]) -> tuple[pd.DataFrame, pd.DataFrame]:
    if not candidates:
        raise ValueError("at least one candidate is required")
    if len({candidate.label for candidate in candidates}) != len(candidates):
        raise ValueError("candidate labels must be unique")

    result_frames = []
    summary_frames = []
    for order, candidate in enumerate(candidates):
        results, summary = _read_candidate(candidate, order)
        if results is not None:
            result_frames.append(results)
        summary_frames.append(summary)

    merged_results = pd.concat(result_frames, ignore_index=True) if result_frames else pd.DataFrame()
    merged_summary = pd.concat(summary_frames, ignore_index=True)
    return merged_results, merged_summary


def _scope_summary(summary: pd.DataFrame, suite: str | None) -> tuple[pd.DataFrame, str]:
    if suite:
        scoped = summary[summary["suite"] == suite].copy()
        if scoped.empty:
            raise ValueError(f"suite not found in merged summary: {suite}")
        return scoped, suite
    return summary.copy(), "__all__"


def build_total_comparison(summary: pd.DataFrame, metric: str, suite: str | None = None) -> pd.DataFrame:
    scoped, suite_scope = _scope_summary(summary, suite)
    metric_col = _metric_column(scoped, metric)
    total = scoped[scoped["group"] == "total"].copy()
    if total.empty:
        raise ValueError("merged summary has no group=total rows")
    total[metric_col] = pd.to_numeric(total[metric_col], errors="coerce").fillna(0.0)
    grouped = (
        total.groupby(["candidate_order", "candidate"], as_index=False, sort=True)[metric_col]
        .sum()
        .rename(columns={metric_col: "value_us"})
    )
    grouped = grouped.sort_values(["candidate_order", "candidate"]).reset_index(drop=True)
    positive = grouped[grouped["value_us"] > 0]
    if positive.empty:
        baseline_us = float("nan")
        baseline_candidate = ""
        grouped["relative_to_best"] = float("nan")
    else:
        best_idx = positive["value_us"].idxmin()
        baseline_us = float(positive.loc[best_idx, "value_us"])
        baseline_candidate = str(positive.loc[best_idx, "candidate"])
        grouped["relative_to_best"] = grouped["value_us"] / baseline_us
    grouped.insert(0, "suite_scope", suite_scope)
    grouped["metric"] = metric
    grouped["baseline_us"] = baseline_us
    grouped["baseline_candidate"] = baseline_candidate
    return grouped


def _component_name(rows: pd.DataFrame, prefix: str) -> pd.Series:
    names = rows["group"].astype(str).str[len(prefix):]
    stages = rows.get("stage", pd.Series("", index=rows.index)).fillna("").astype(str)
    non_empty_stages = {stage for stage in stages.unique() if stage}
    if len(non_empty_stages) <= 1:
        return names
    return stages.where(stages == "", stages + ":") + names


def build_component_comparison(
    summary: pd.DataFrame,
    metric: str,
    breakdown: str = "kernel",
    suite: str | None = None,
) -> pd.DataFrame:
    scoped, suite_scope = _scope_summary(summary, suite)
    metric_col = _metric_column(scoped, metric)
    prefix = f"{breakdown}:"
    rows = scoped[scoped["group"].astype(str).str.startswith(prefix)].copy()
    if rows.empty:
        raise ValueError(f"merged summary has no group={prefix}* rows")
    rows[metric_col] = pd.to_numeric(rows[metric_col], errors="coerce").fillna(0.0)
    rows["component"] = _component_name(rows, prefix)
    grouped = (
        rows.groupby(["candidate_order", "candidate", "component"], as_index=False, sort=True)[metric_col]
        .sum()
        .rename(columns={metric_col: "value_us"})
    )
    total = build_total_comparison(summary, metric, suite)
    total_cols = total[["candidate_order", "candidate", "value_us", "relative_to_best", "baseline_us", "baseline_candidate"]]
    total_cols = total_cols.rename(columns={
        "value_us": "candidate_total_us",
        "relative_to_best": "candidate_relative_to_best",
    })
    grouped = grouped.merge(total_cols, on=["candidate_order", "candidate"], how="left")
    grouped.insert(0, "suite_scope", suite_scope)
    grouped["metric"] = metric
    grouped["breakdown"] = breakdown
    grouped["relative_component_to_best"] = grouped["value_us"] / grouped["baseline_us"]
    return grouped.sort_values(["candidate_order", "candidate", "component"]).reset_index(drop=True)


def limit_components(components: pd.DataFrame, top_n: int) -> pd.DataFrame:
    if top_n <= 0:
        return components.copy()
    totals = components.groupby("component")["value_us"].sum().sort_values(ascending=False)
    if len(totals) <= top_n:
        return components.copy()
    keep = set(totals.head(top_n).index)
    out = components.copy()
    out["component"] = out["component"].where(out["component"].isin(keep), "__other__")
    agg_cols = [
        "suite_scope", "metric", "breakdown", "candidate_order", "candidate",
        "component", "candidate_total_us", "candidate_relative_to_best",
        "baseline_us", "baseline_candidate",
    ]
    return (
        out.groupby(agg_cols, as_index=False, sort=True)[["value_us", "relative_component_to_best"]]
        .sum()
        .sort_values(["candidate_order", "candidate", "component"])
        .reset_index(drop=True)
    )


def _save(fig, out_dir: Path, name: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_dir / f"{name}.png", dpi=180, bbox_inches="tight")
    fig.savefig(out_dir / f"{name}.pdf", bbox_inches="tight")
    plt.close(fig)


def _ordered_labels(df: pd.DataFrame) -> list[str]:
    return (
        df[["candidate_order", "candidate"]]
        .drop_duplicates()
        .sort_values(["candidate_order", "candidate"])["candidate"]
        .astype(str)
        .tolist()
    )


def _annotate_bars(ax, values: list[float], fmt: str) -> None:
    if not values:
        return
    ymax = max(values) if max(values) > 0 else 1.0
    for i, value in enumerate(values):
        ax.text(i, value + ymax * 0.015, fmt.format(value), ha="center", va="bottom", fontsize=9)


def plot_total_comparison(total: pd.DataFrame, out_dir: Path, metric: str) -> None:
    rows = total.sort_values(["candidate_order", "candidate"])
    labels = rows["candidate"].astype(str).tolist()
    values = rows["value_us"].astype(float).tolist()
    relatives = rows["relative_to_best"].astype(float).tolist()
    width = max(6.5, 1.2 * len(labels) + 2.0)

    fig, ax = plt.subplots(figsize=(width, 4.8))
    ax.bar(labels, values, color="#2f6f73")
    ax.set_ylabel(f"weighted total {metric} latency (us)")
    ax.set_title("Candidate total latency")
    ax.grid(axis="y", alpha=0.25)
    _annotate_bars(ax, values, "{:.1f}")
    _save(fig, out_dir, f"total_latency_{metric}")

    fig, ax = plt.subplots(figsize=(width, 4.8))
    ax.bar(labels, relatives, color="#4a677d")
    ax.axhline(1.0, color="#333333", linewidth=1.0, linestyle="--")
    ax.set_ylabel("relative to best")
    ax.set_title("Candidate total latency, normalized")
    ax.grid(axis="y", alpha=0.25)
    _annotate_bars(ax, relatives, "{:.3f}x")
    _save(fig, out_dir, f"total_latency_{metric}_relative")


def _component_order(components: pd.DataFrame) -> list[str]:
    return (
        components.groupby("component")["value_us"]
        .sum()
        .sort_values(ascending=False)
        .index.astype(str)
        .tolist()
    )


def _plot_stacked(
    components: pd.DataFrame,
    out_dir: Path,
    metric: str,
    breakdown: str,
    value_col: str,
    ylabel: str,
    name_suffix: str,
) -> None:
    labels = _ordered_labels(components)
    order = _component_order(components)
    pivot = (
        components.pivot_table(index="candidate", columns="component", values=value_col, aggfunc="sum", fill_value=0.0)
        .reindex(index=labels, columns=order, fill_value=0.0)
    )
    width = max(8.0, 1.2 * len(labels) + 4.0)
    height = max(5.2, min(9.5, 0.22 * len(order) + 4.0))
    fig, ax = plt.subplots(figsize=(width, height))
    bottoms = [0.0] * len(labels)
    x = list(range(len(labels)))
    for i, component in enumerate(order):
        values = pivot[component].astype(float).tolist()
        ax.bar(x, values, bottom=bottoms, label=component, color=PALETTE[i % len(PALETTE)])
        bottoms = [base + value for base, value in zip(bottoms, values)]
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel(ylabel)
    ax.set_title(f"Candidate {breakdown} breakdown")
    ax.grid(axis="y", alpha=0.25)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), fontsize=8)
    _save(fig, out_dir, f"{breakdown}_stacked_latency_{metric}{name_suffix}")


def plot_component_comparison(components: pd.DataFrame, out_dir: Path, metric: str, breakdown: str) -> None:
    _plot_stacked(
        components,
        out_dir,
        metric,
        breakdown,
        "value_us",
        f"weighted total {metric} latency (us)",
        "",
    )
    _plot_stacked(
        components,
        out_dir,
        metric,
        breakdown,
        "relative_component_to_best",
        "relative contribution to best total",
        "_relative",
    )


def compare_candidates(
    candidates: list[CandidateInput],
    out_dir: Path,
    metric: str = "p50",
    suite: str | None = None,
    breakdown: str = "kernel",
    top_components: int = 24,
    make_plots: bool = True,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    merged_results, merged_summary = load_candidates(candidates)
    if not merged_results.empty:
        merged_results.to_csv(out_dir / "merged_results.csv", index=False)
    merged_summary.to_csv(out_dir / "merged_summary.csv", index=False)

    total = build_total_comparison(merged_summary, metric, suite)
    components = build_component_comparison(merged_summary, metric, breakdown, suite)
    plot_components = limit_components(components, top_components)

    total.to_csv(out_dir / "compare_total.csv", index=False)
    components.to_csv(out_dir / f"compare_{breakdown}.csv", index=False)
    plot_components.to_csv(out_dir / f"compare_{breakdown}_plot.csv", index=False)

    if make_plots:
        fig_dir = out_dir / "figures"
        plot_total_comparison(total, fig_dir, metric)
        plot_component_comparison(plot_components, fig_dir, metric, breakdown)
        print(f"wrote figures to {fig_dir}")
    print(f"wrote comparison CSVs to {out_dir}")
