from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


def _save(fig, out_dir: Path, name: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_dir / f"{name}.png", dpi=180)
    fig.savefig(out_dir / f"{name}.pdf")
    plt.close(fig)


def _successful(results: pd.DataFrame) -> pd.DataFrame:
    ok = results[results["status"] == "pass"].copy()
    for col in ("p50_us", "avg_us", "p95_us", "calls_per_forward"):
        ok[col] = pd.to_numeric(ok[col], errors="coerce").fillna(0.0)
    return ok


def plot_case_latency(results: pd.DataFrame, out_dir: Path) -> None:
    ok = _successful(results).sort_values("p50_us", ascending=True)
    if ok.empty:
        return
    height = max(4.0, min(18.0, 0.32 * len(ok) + 1.8))
    fig, ax = plt.subplots(figsize=(10.5, height))
    ax.barh(ok["case_id"], ok["p50_us"], color="#2f6f73")
    ax.set_xlabel("p50 latency (us)")
    ax.set_ylabel("case")
    ax.set_title("Per-case FPGA latency")
    ax.grid(axis="x", alpha=0.25)
    _save(fig, out_dir, "case_latency_p50")


def plot_weighted_breakdown(results: pd.DataFrame, out_dir: Path, group_col: str, name: str) -> None:
    ok = _successful(results)
    if ok.empty:
        return
    ok["weighted_p50_us"] = ok["p50_us"] * ok["calls_per_forward"]
    group = ok.groupby(group_col, sort=True)["weighted_p50_us"].sum().sort_values(ascending=False)
    if group.empty:
        return
    fig, ax = plt.subplots(figsize=(10.5, max(4.0, min(12.0, 0.4 * len(group) + 1.8))))
    ax.barh(group.index.astype(str), group.values, color="#9a5b2f")
    ax.invert_yaxis()
    ax.set_xlabel("weighted p50 latency (us)")
    ax.set_ylabel(group_col)
    ax.set_title(f"Forward-pass weighted latency by {group_col}")
    ax.grid(axis="x", alpha=0.25)
    _save(fig, out_dir, name)


def plot_status(results: pd.DataFrame, out_dir: Path) -> None:
    counts = results["status"].fillna("unknown").value_counts().sort_index()
    fig, ax = plt.subplots(figsize=(6.5, 4.0))
    ax.bar(counts.index.astype(str), counts.values, color="#4a677d")
    ax.set_ylabel("case count")
    ax.set_title("Benchmark status")
    ax.grid(axis="y", alpha=0.25)
    _save(fig, out_dir, "status_summary")


def visualize(results_csv: Path, out_dir: Path) -> None:
    results = pd.read_csv(results_csv)
    plot_case_latency(results, out_dir)
    plot_weighted_breakdown(results, out_dir, "name", "weighted_by_kernel")
    plot_weighted_breakdown(results, out_dir, "kind", "weighted_by_kind")
    plot_status(results, out_dir)
    print(f"wrote figures to {out_dir}")
