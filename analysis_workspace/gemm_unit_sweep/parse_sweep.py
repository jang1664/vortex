"""Aggregate area, timing, and power results from the gemm_unit sweep.

Reads each synth point's reports/14_*.mapped.area.rpt (and the corresponding
12_*.mapped.timing.rpt for WNS and 18_*.mapped.power.rpt for power) under
    build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0/syn_topo_wonce_*_col*.run1*/
and emits:
    sweep_results.csv       - one row per discovered (period, wonce, col_tile).
    sweep_area_<period>.png - heatmap per period.
    sweep_lines_<period>.png - line plot per period.

Run after `sweep.py` has populated the points:
    conda activate stable
    python analysis_workspace/gemm_unit_sweep/parse_sweep.py
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from hwexplorer.report_parser import SynopsysDesignCompilerAreaParser

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
BUILD_RUN_DIR = VORTEX / "build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0"

WONCE_VALUES = ["off", "on"]
COL_TILE_VALUES = [1, 8, 16, 32]
DEFAULT_PERIOD_NS = 10.0

RE_WNS = re.compile(r"^\s*slack\s+\(\w+\)\s+(-?[\d.]+)", re.IGNORECASE | re.MULTILINE)
RE_CORE_AREA = re.compile(
    r"^\s*Core Area:\s+(?P<core_area>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)",
    re.IGNORECASE | re.MULTILINE,
)
RE_UTIL_RATIO = re.compile(
    r"^\s*Utilization Ratio:\s+(?P<util>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)",
    re.IGNORECASE | re.MULTILINE,
)
RE_POWER_TOP = re.compile(
    r"^VX_gemm_unit_top\s+"
    r"(?P<switch>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)\s+"
    r"(?P<internal>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)\s+"
    r"(?P<leakage>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)\s+"
    r"(?P<total>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)\s+"
    r"(?P<percent>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)",
    re.IGNORECASE | re.MULTILINE,
)
RE_SYN_DIR = re.compile(
    r"^syn_topo_wonce_(?P<wonce>off|on)_col(?P<col_tile>\d+)\.run1"
    r"(?:_(?P<period_tag>p(?:m?\d+(?:p\d+)?)ns))?$"
)


@dataclass(frozen=True)
class SweepPoint:
    period_ns: float
    wonce: str
    col_tile: int
    syn_dir: Path


def decode_period_tag(tag: str | None) -> float:
    if tag is None:
        return DEFAULT_PERIOD_NS
    body = tag.removeprefix("p").removesuffix("ns")
    return float(body.replace("m", "-").replace("p", "."))


def period_tag(period_ns: float) -> str:
    return f"p{period_ns:g}ns".replace(".", "p").replace("-", "m")


def discover_points() -> list[SweepPoint]:
    points = []
    if not BUILD_RUN_DIR.exists():
        return points

    for syn_dir in BUILD_RUN_DIR.iterdir():
        if not syn_dir.is_dir():
            continue
        m = RE_SYN_DIR.match(syn_dir.name)
        if not m:
            continue
        points.append(SweepPoint(
            period_ns=decode_period_tag(m.group("period_tag")),
            wonce=m.group("wonce"),
            col_tile=int(m.group("col_tile")),
            syn_dir=syn_dir,
        ))

    return sorted(points, key=lambda p: (p.period_ns, p.wonce, p.col_tile))


def parse_power_report(rpt_power: Path) -> dict[str, float | None]:
    power = {
        "switch_power_mw": None,
        "internal_power_mw": None,
        "leakage_power_uw": None,
        "leakage_power_mw": None,
        "total_power_mw": None,
    }
    if not rpt_power.exists():
        return power

    txt = rpt_power.read_text(errors="ignore")
    m = RE_POWER_TOP.search(txt)
    if not m:
        return power

    leakage_uw = float(m.group("leakage"))
    power.update({
        "switch_power_mw": float(m.group("switch")),
        "internal_power_mw": float(m.group("internal")),
        "leakage_power_uw": leakage_uw,
        "leakage_power_mw": leakage_uw / 1000.0,
        "total_power_mw": float(m.group("total")),
    })
    return power


def parse_topo_area_overhead(rpt_area: Path,
                             total_cell_area: float | None) -> dict[str, float | None]:
    area = {
        "core_util": None,
        "core_area": None,
        "pnr_overhead_area": None,
        "pnr_overhead_ratio": None,
        "total_area_with_pnr": None,
    }
    if not rpt_area.exists():
        return area

    txt = rpt_area.read_text(errors="ignore")
    m_area = RE_CORE_AREA.search(txt)
    m_util = RE_UTIL_RATIO.search(txt)
    core_area = float(m_area.group("core_area")) if m_area else None
    core_util = float(m_util.group("util")) if m_util else None

    if core_area is None and total_cell_area is not None and core_util:
        core_area = total_cell_area / core_util

    area["core_util"] = core_util
    area["core_area"] = core_area
    area["total_area_with_pnr"] = core_area
    if core_area is not None and total_cell_area is not None:
        overhead = core_area - total_cell_area
        area["pnr_overhead_area"] = overhead
        area["pnr_overhead_ratio"] = overhead / total_cell_area
    elif core_util:
        area["pnr_overhead_ratio"] = (1.0 / core_util) - 1.0
    return area


def parse_one(point: SweepPoint) -> dict:
    rpt_area = point.syn_dir / "reports/14_VX_gemm_unit_top.mapped.area.rpt"
    rpt_timing = point.syn_dir / "reports/12_VX_gemm_unit_top.mapped.timing.rpt"
    rpt_power = point.syn_dir / "reports/18_VX_gemm_unit_top.mapped.power.rpt"

    row = {
        "period_ns": point.period_ns,
        "wonce": point.wonce,
        "col_tile": point.col_tile,
        "syn_dir": str(point.syn_dir.relative_to(VORTEX)),
        "exists": rpt_area.exists(),
        "total_cell_area": None, "comb_area": None, "non_comb_area": None,
        "macro_area": None, "buf_inv_area": None,
        "core_util": None, "core_area": None,
        "pnr_overhead_area": None, "pnr_overhead_ratio": None,
        "total_area_with_pnr": None,
        "num_cells": None, "num_macros": None,
        "wns": None,
        "switch_power_mw": None,
        "internal_power_mw": None,
        "leakage_power_uw": None,
        "leakage_power_mw": None,
        "total_power_mw": None,
    }
    if not rpt_area.exists():
        return row

    parser = SynopsysDesignCompilerAreaParser()
    db = parser.load(str(rpt_area))
    m = db.metadata
    row.update({
        "total_cell_area": float(m.get("total_cell_area", 0.0) or 0.0),
        "comb_area":       float(m.get("combinational_area", 0.0) or 0.0),
        "non_comb_area":   float(m.get("noncombinational_area", 0.0) or 0.0),
        "macro_area":      float(m.get("macro_black_box_area", 0.0) or 0.0),
        "buf_inv_area":    float(m.get("buf_inv_area", 0.0) or 0.0),
        "num_cells":       int(m.get("num_cells", 0) or 0),
        "num_macros":      int(m.get("num_macros", 0) or 0),
    })
    row.update(parse_topo_area_overhead(rpt_area, row["total_cell_area"]))

    if rpt_timing.exists():
        txt = rpt_timing.read_text(errors="ignore")
        ms = RE_WNS.findall(txt)
        if ms:
            row["wns"] = float(ms[0])

    row.update(parse_power_report(rpt_power))
    return row


def heatmap(df: pd.DataFrame, out_path: Path, period_ns: float):
    pivot = df.pivot(index="wonce", columns="col_tile",
                     values="total_cell_area") / 1e6  # mm²
    pivot = pivot.reindex(index=WONCE_VALUES, columns=COL_TILE_VALUES)

    fig, ax = plt.subplots(figsize=(8, 3.6))
    im = ax.imshow(pivot.values, aspect="auto", cmap="viridis")
    ax.set_xticks(range(len(COL_TILE_VALUES)))
    ax.set_xticklabels([str(c) for c in COL_TILE_VALUES])
    ax.set_yticks(range(len(WONCE_VALUES)))
    ax.set_yticklabels([f"WLOAD_AT_ONCE={w}" for w in WONCE_VALUES])
    ax.set_xlabel("MXU_COL_TILE")
    ax.set_title(f"VX_gemm_unit total cell area (mm²), period={period_ns:g} ns")
    finite = pivot.values[~np.isnan(pivot.values)]
    mean = finite.mean() if finite.size else 0.0
    for i in range(pivot.shape[0]):
        for j in range(pivot.shape[1]):
            v = pivot.values[i, j]
            label = "—" if np.isnan(v) else f"{v:.3f}"
            ax.text(j, i, label, ha="center", va="center",
                    color="white" if not np.isnan(v) and v > mean else "#111",
                    fontsize=9)
    fig.colorbar(im, ax=ax, label="mm²")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_path}")


def heatmap_pnr_area(df: pd.DataFrame, out_path: Path, period_ns: float):
    pivot = df.pivot(index="wonce", columns="col_tile",
                     values="total_area_with_pnr") / 1e6  # mm²
    pivot = pivot.reindex(index=WONCE_VALUES, columns=COL_TILE_VALUES)

    fig, ax = plt.subplots(figsize=(8, 3.6))
    im = ax.imshow(pivot.values, aspect="auto", cmap="magma")
    ax.set_xticks(range(len(COL_TILE_VALUES)))
    ax.set_xticklabels([str(c) for c in COL_TILE_VALUES])
    ax.set_yticks(range(len(WONCE_VALUES)))
    ax.set_yticklabels([f"WLOAD_AT_ONCE={w}" for w in WONCE_VALUES])
    ax.set_xlabel("MXU_COL_TILE")
    ax.set_title(f"VX_gemm_unit PnR-adjusted area (mm²), period={period_ns:g} ns")
    finite = pivot.values[~np.isnan(pivot.values)]
    mean = finite.mean() if finite.size else 0.0
    for i in range(pivot.shape[0]):
        for j in range(pivot.shape[1]):
            v = pivot.values[i, j]
            label = "-" if np.isnan(v) else f"{v:.3f}"
            ax.text(j, i, label, ha="center", va="center",
                    color="white" if not np.isnan(v) and v > mean else "#111",
                    fontsize=9)
    fig.colorbar(im, ax=ax, label="mm²")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_path}")


def lines(df: pd.DataFrame, out_path: Path, period_ns: float):
    fig, axes = plt.subplots(1, 2, figsize=(13, 4.6), sharex=True)
    axA, axC = axes
    for wonce, marker in zip(WONCE_VALUES, ("o", "s")):
        sub = df[df["wonce"] == wonce].sort_values("col_tile")
        x = sub["col_tile"].to_numpy()
        axA.plot(x, sub["total_cell_area"] / 1e6, marker=marker, linewidth=1.7,
                 label=f"WLOAD_AT_ONCE={wonce}: total")
        axC.plot(x, sub["comb_area"] / 1e6,     marker=marker, linestyle="-",
                 label=f"wonce={wonce}: comb")
        axC.plot(x, sub["non_comb_area"] / 1e6, marker=marker, linestyle="--",
                 label=f"wonce={wonce}: non-comb")
        axC.plot(x, sub["macro_area"] / 1e6,    marker=marker, linestyle=":",
                 label=f"wonce={wonce}: macro")

    for ax in (axA, axC):
        ax.set_xscale("log", base=2)
        ax.set_xticks(COL_TILE_VALUES)
        ax.set_xticklabels([str(c) for c in COL_TILE_VALUES])
        ax.set_xlabel("MXU_COL_TILE")
        ax.set_ylabel("Area (mm²)")
        ax.grid(True, which="both", alpha=0.3)
        ax.set_axisbelow(True)
        ax.legend(fontsize=8, framealpha=0.95)
    axA.set_title(f"Total cell area, period={period_ns:g} ns")
    axC.set_title("Cell-area components (combi / non-combi / macro)")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out_path}")


def main():
    points = discover_points()
    if not points:
        print(f"[parse] no sweep directories found under {BUILD_RUN_DIR}")
        return

    rows = [parse_one(point) for point in points]
    df = pd.DataFrame(rows)
    csv_path = HERE / "sweep_results.csv"
    df.to_csv(csv_path, index=False)
    print(f"wrote {csv_path}")
    cols_show = ["period_ns", "wonce", "col_tile", "exists", "total_cell_area",
                 "core_util", "total_area_with_pnr", "pnr_overhead_ratio",
                 "comb_area", "non_comb_area", "macro_area", "wns",
                 "switch_power_mw", "internal_power_mw", "leakage_power_mw",
                 "total_power_mw"]
    print(df[cols_show].to_string(index=False))

    have = df[df["exists"]].copy()
    if have.empty:
        print("[parse] no completed runs yet; skipping plots")
        return

    for period_ns, sub in have.groupby("period_ns", sort=True):
        tag = period_tag(float(period_ns))
        heatmap(sub, HERE / f"sweep_area_{tag}.png", float(period_ns))
        heatmap_pnr_area(sub, HERE / f"sweep_area_pnr_{tag}.png", float(period_ns))
        lines(sub, HERE / f"sweep_lines_{tag}.png", float(period_ns))


if __name__ == "__main__":
    main()
