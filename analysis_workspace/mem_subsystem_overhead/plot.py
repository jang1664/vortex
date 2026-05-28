"""Plot memory-subsystem overhead vs one VX_gemm_unit.

Inputs:
  area.csv     (cell-area breakdown per top × point)
  routing.csv  (DC-Topo routing-difficulty proxies: util, congestion overflow)

All figures apply two conventions per user request:
  - GEMM-unit area always includes its own PnR overhead (cell / util_gemm).
  - CAP-intrinsic SRAM bit-cell area (sram_base) is excluded everywhere.

Outputs (PNG + PDF):
  fig1_stacked_vs_gemm     Stacked xbar/ctrl/sram_peri/PnR + gemm_unit reference.
  fig2_ratio_to_gemm       Cumulative overhead per point as gemm-die equivalents,
                           including a PnR-whitespace variant.
  fig3_scaling             Log-log of overhead area vs port count, with PnR overlay.
  fig4_routing_proxies     DC-Topo proxies for routing difficulty: utilization
                           drops + congestion overflow rises as xbar grows.
  fig7_tops_baseline_vs_fpint   TOPS/mm² across 4 cumulative area sets (gemm-w/PnR
                                → +xc → +sram_peri → +memory system PnR full die).
  fig8_tops_recovery           Side-by-side subplots comparing BASE FPFP vs
                               FPxINT real across two MXU-size sweeps:
                               16×16 → 32×32 and 32×32 → 64×64. Y-axis is
                               relative TOPS/mm² with per-set Baseline = 1.0.
                               Rule: L = N²/16, D = A = max(1, N²/128). The
                               64×64 FPxINT memory (L=256) is log-log extrapolated.
                               SRAM-peripheral banking overhead is charged only
                               to FPxINT, not to the FPFP baseline.
"""

from __future__ import annotations

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
CSV = HERE / "area.csv"

ORDER = ["L1", "L2", "L3", "L4",
         "C0", "C1", "C2", "C3", "C4",
         "A0", "A1", "A2", "A3", "A4"]
TOP_OF = {
    "L1": "VX_local_mem_top", "L2": "VX_local_mem_top", "L3": "VX_local_mem_top", "L4": "VX_local_mem_top",
    "C0": "VX_cache_top",     "C1": "VX_cache_top",     "C2": "VX_cache_top",     "C3": "VX_cache_top", "C4": "VX_cache_top",
    "A0": "VX_axi_adapter",   "A1": "VX_axi_adapter",   "A2": "VX_axi_adapter",   "A3": "VX_axi_adapter", "A4": "VX_axi_adapter",
}
COLORS = {
    "xbar":     "#d9774a",   # interconnect — burnt orange (the bit we're measuring)
    "ctrl":     "#f3c969",   # MSHR / arb / fill / replace logic — wheat
    "sram_peri":"#a4c8c9",   # SRAM peripheral overhead (decoder, sense-amp dup) — pale teal
    "sram_base":"#5a7891",   # SRAM bit-cell baseline (fixed by CAP spec)   — dark blue-grey
    "pnr":      "#7d6b8c",   # PnR whitespace (DC-Topo: cell × (1/util - 1)) — dusty purple
    "gemm":     "#444444",   # VX_gemm_unit_top reference — dark grey
}

# DC-Topographical PnR overhead model.
# Synthesized gemm_32 util is reused for any gemm size (per user instruction).
UTIL_GEMM = 0.546


def _pnr_oh(cell_area: float, util: float) -> float:
    """PnR whitespace = cell × (1/util - 1) ≡ cell/util - cell."""
    if util <= 0:
        return 0.0
    return cell_area * (1.0 / util - 1.0)


def _util_of(routing, label):
    top = TOP_OF[label]
    r = routing.get((top, label))
    return r["util"] if r else 0.0


def split_sram(table):
    """Compute sram_baseline (=min sram per top) and sram_peri (=sram-baseline).
    Returns dict {(label): {kind: area}} with extra keys 'sram_base' and 'sram_peri'.
    """
    out = {}
    by_top = {}
    for lb in ORDER:
        sram = get(table, lb, "sram")
        top = TOP_OF[lb]
        by_top.setdefault(top, []).append(sram)
    baselines = {t: (min(v) if v else 0.0) for t, v in by_top.items()}
    for lb in ORDER:
        top = TOP_OF[lb]
        sram = get(table, lb, "sram")
        b = baselines[top]
        out[lb] = {
            "xbar":     get(table, lb, "xbar"),
            "ctrl":     get(table, lb, "ctrl"),
            "sram_base": b,
            "sram_peri": max(0.0, sram - b),
        }
    return out


def load():
    table = {}  # (label, kind) -> area
    with CSV.open() as f:
        for row in csv.DictReader(f):
            key = (row["label"], row["kind"])
            table[key] = float(row["area_um2"])
    return table


def get(table, label, kind):
    return table.get((label, kind), 0.0)


def fig1_stacked(table):
    routing = load_routing()
    gemm = get(table, "WKQ", "total")
    pnr_gemm = _pnr_oh(gemm, UTIL_GEMM)
    s = split_sram(table)
    xbars  = [s[lb]["xbar"]      / 1e6 for lb in ORDER]
    ctrls  = [s[lb]["ctrl"]      / 1e6 for lb in ORDER]
    speris = [s[lb]["sram_peri"] / 1e6 for lb in ORDER]
    pnrs = []
    for lb in ORDER:
        cell_no_base = s[lb]["xbar"] + s[lb]["ctrl"] + s[lb]["sram_peri"]
        pnrs.append(_pnr_oh(cell_no_base, _util_of(routing, lb)) / 1e6)

    fig, ax = plt.subplots(figsize=(11.5, 5.2))
    x = np.arange(len(ORDER) + 1)  # +1 for gemm

    # Stacked: xbar | ctrl | sram_peri | PnR whitespace
    # (CAP-intrinsic SRAM storage is excluded from every layer so the bars
    # represent bank-induced overhead only.)
    ax.bar(x[:-1], xbars, color=COLORS["xbar"], label="xbar (interconnect)", edgecolor="black", linewidth=0.4)
    bot = list(xbars)
    ax.bar(x[:-1], ctrls, bottom=bot, color=COLORS["ctrl"], label="ctrl / arb / MSHR", edgecolor="black", linewidth=0.4)
    bot = [a + b for a, b in zip(bot, ctrls)]
    ax.bar(x[:-1], speris, bottom=bot, color=COLORS["sram_peri"],
           label="SRAM peri (decoder/sense-amp dup from banking)", edgecolor="black", linewidth=0.4)
    bot = [a + b for a, b in zip(bot, speris)]
    ax.bar(x[:-1], pnrs, bottom=bot, color=COLORS["pnr"],
           label="PnR whitespace (cell × (1/util − 1))",
           edgecolor="black", linewidth=0.4, hatch="///")

    # gemm_unit reference bar — cell + PnR (gemm area always includes PnR).
    ax.bar(x[-1], gemm / 1e6, color=COLORS["gemm"], label="VX_gemm_unit_top (WKQ, cell)", edgecolor="black", linewidth=0.4)
    ax.bar(x[-1], pnr_gemm / 1e6, bottom=gemm / 1e6, color=COLORS["pnr"],
           edgecolor="black", linewidth=0.4, hatch="///")

    gemm_die = (gemm + pnr_gemm) / 1e6

    # 1x / 2x / 4x reference lines (gemm full-die, w/ PnR)
    ymax = ax.get_ylim()[1]
    for k, ls in [(1, "--"), (2, ":"), (4, "-.")]:
        y = k * gemm_die
        if y < ymax * 1.05:
            ax.axhline(y, color=COLORS["gemm"], linestyle=ls, linewidth=0.9, alpha=0.55)
            ax.text(len(ORDER) - 0.3, y, f" {k}× gemm (w/ PnR)", color=COLORS["gemm"],
                    fontsize=8, va="bottom", ha="left", alpha=0.7)

    # Annotate effective overhead (= xbar + ctrl + sram_peri + PnR) above each mem bar
    for i, lb in enumerate(ORDER):
        icn_eff = xbars[i] + ctrls[i] + speris[i] + pnrs[i]
        ax.text(i, icn_eff + ymax * 0.005,
                f"icn={icn_eff*1000:.0f}k", ha="center", fontsize=7, color="#222")

    ax.set_xticks(x)
    ax.set_xticklabels(ORDER + ["GEMM\nunit"], fontsize=9)
    ax.set_ylabel("Area (mm² equivalent, ×10⁶ µm²)")
    ax.set_title("Bank-induced overhead per memory-subsystem point vs one VX_gemm_unit_top\n"
                 "(xbar + ctrl + SRAM peri + PnR whitespace; CAP-intrinsic storage excluded. "
                 "Samsung 28LPP, DC Topo, 10 ns)",
                 fontsize=10.5)
    ax.legend(loc="upper left", framealpha=0.95, fontsize=8.5)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)

    # Group labels under x-axis
    group_pos = {"LMEM (L*)": (0, 3), "DCACHE (C*)": (4, 7), "AXI adapter (A*)": (8, 11)}
    for label, (s, e) in group_pos.items():
        ax.annotate(label,
                    xy=((s + e) / 2, -0.13), xycoords=("data", "axes fraction"),
                    ha="center", va="top", fontsize=9, color="#444")

    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig1_stacked_vs_gemm.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig1_stacked_vs_gemm.{png,pdf}")


def fig2_ratio(table):
    routing = load_routing()
    gemm = get(table, "WKQ", "total")
    # GEMM-unit reference always includes PnR overhead (cell + PnR = cell / util).
    gemm_die = gemm / UTIL_GEMM
    s = split_sram(table)
    r_xbar = [s[lb]["xbar"] / gemm_die for lb in ORDER]
    r_xc   = [(s[lb]["xbar"] + s[lb]["ctrl"]) / gemm_die for lb in ORDER]
    r_eff  = [(s[lb]["xbar"] + s[lb]["ctrl"] + s[lb]["sram_peri"]) / gemm_die for lb in ORDER]
    r_full = []
    for lb in ORDER:
        cell = s[lb]["xbar"] + s[lb]["ctrl"] + s[lb]["sram_peri"]
        r_full.append((cell + _pnr_oh(cell, _util_of(routing, lb))) / gemm_die)

    x = np.arange(len(ORDER))
    width = 0.21
    fig, ax = plt.subplots(figsize=(12.5, 4.8))
    b1 = ax.bar(x - 1.5*width, r_xbar, width, color=COLORS["xbar"], label="xbar only",
                edgecolor="black", linewidth=0.4)
    b2 = ax.bar(x - 0.5*width, r_xc,   width, color=COLORS["ctrl"], label="xbar + ctrl",
                edgecolor="black", linewidth=0.4)
    b3 = ax.bar(x + 0.5*width, r_eff,  width, color=COLORS["sram_peri"],
                label="xbar + ctrl + SRAM peri",
                edgecolor="black", linewidth=0.4)
    b4 = ax.bar(x + 1.5*width, r_full, width, color=COLORS["pnr"],
                label="xbar + ctrl + SRAM peri + PnR whitespace (full die)",
                edgecolor="black", linewidth=0.4, hatch="///")

    ax.axhline(1.0, color=COLORS["gemm"], linestyle="--", linewidth=1.0)
    ax.text(len(ORDER) - 0.6, 1.02, "= 1 GEMM unit (w/ PnR)", color=COLORS["gemm"], fontsize=8.5)

    for bars in (b1, b2, b3, b4):
        for b in bars:
            h = b.get_height()
            if h > 0:
                ax.text(b.get_x() + b.get_width() / 2, h + 0.05,
                        f"{h:.2f}", ha="center", fontsize=6.5, color="#222")

    ax.set_xticks(x)
    ax.set_xticklabels(ORDER, fontsize=9)
    ax.set_ylabel("area / area(VX_gemm_unit_top, cell + PnR)")
    ax.set_title("Interconnect overhead expressed in GEMM-unit equivalents\n"
                 "(GEMM reference always includes PnR overhead; CAP-intrinsic SRAM excluded)",
                 fontsize=10.5)
    ax.legend(loc="upper left", framealpha=0.95, fontsize=9)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)

    group_pos = {"LMEM": (0, 3), "DCACHE": (4, 7), "AXI adapter": (8, 11)}
    for label, (s, e) in group_pos.items():
        ax.annotate(label,
                    xy=((s + e) / 2, -0.13), xycoords=("data", "axes fraction"),
                    ha="center", va="top", fontsize=9, color="#444")

    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig2_ratio_to_gemm.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig2_ratio_to_gemm.{png,pdf}")


def fig3_scaling(table):
    routing = load_routing()
    gemm = get(table, "WKQ", "total")
    gemm_die = gemm / UTIL_GEMM  # always include PnR for the reference
    s = split_sram(table)
    series = {
        "LMEM":   ["L1", "L2", "L3", "L4"],
        "DCACHE": ["C1", "C2", "C3", "C4"],
        "AXI":    ["A1", "A2", "A3", "A4"],
    }
    LABEL_N = {"L1": 8, "L2": 16, "L3": 32, "L4": 64,
               "C1": 4, "C2":  8, "C3": 16, "C4": 32,
               "A1": 4, "A2":  8, "A3": 16, "A4": 32}
    colors = {"LMEM": "#3a7ca5", "DCACHE": "#d9774a", "AXI": "#5a8a3b"}
    markers = {"LMEM": "o", "DCACHE": "s", "AXI": "^"}

    fig, ax = plt.subplots(figsize=(8.5, 5.0))
    for name, labels in series.items():
        n_actual = [LABEL_N[lb] for lb in labels]
        # Cell-only effective interconnect overhead = xbar + ctrl + sram_peri
        ys = [s[lb]["xbar"] + s[lb]["ctrl"] + s[lb]["sram_peri"] for lb in labels]
        # PnR-included variant = cell / util_i  (CAP-intrinsic SRAM excluded)
        ys_pnr = []
        for lb in labels:
            cell = s[lb]["xbar"] + s[lb]["ctrl"] + s[lb]["sram_peri"]
            u = _util_of(routing, lb)
            ys_pnr.append(cell + _pnr_oh(cell, u))
        pts = [(n, y) for n, y in zip(n_actual, ys) if y > 0]
        if not pts:
            continue
        xs, ys2 = zip(*pts)
        ax.loglog(xs, ys2, marker=markers[name], color=colors[name],
                  label=f"{name} (xbar+ctrl+SRAM peri)", linewidth=1.7, markersize=7)
        # PnR-included line — same color, dotted, thicker marker
        pts_p = [(n, y) for n, y in zip(n_actual, ys_pnr) if y > 0]
        if pts_p:
            xs_p, ys_p = zip(*pts_p)
            ax.loglog(xs_p, ys_p, marker=markers[name], color=colors[name],
                      linestyle=":", linewidth=2.0, markersize=8,
                      markerfacecolor="white", markeredgewidth=1.5,
                      label=f"{name} (+ PnR whitespace)")
        # Also overlay xbar-only as a thinner dashed line for the same top
        ys_xb = [s[lb]["xbar"] for lb in labels]
        pts_xb = [(n, y) for n, y in zip(n_actual, ys_xb) if y > 0]
        if pts_xb:
            xs2, ys2x = zip(*pts_xb)
            ax.loglog(xs2, ys2x, marker=markers[name], color=colors[name],
                      linestyle="--", linewidth=1.0, markersize=5, alpha=0.6,
                      label=f"{name} (xbar only)")

    ax.axhline(gemm_die, color=COLORS["gemm"], linestyle="--", linewidth=1.0)
    ax.text(4.1, gemm_die * 1.05, "1× VX_gemm_unit_top (w/ PnR)",
            color=COLORS["gemm"], fontsize=8.5)

    # Reference slopes
    xx = np.array([4, 64])
    base = 5e3
    ax.loglog(xx, base * xx, color="#888", linestyle=":", linewidth=0.8)
    ax.text(64, base * 64 * 1.05, "O(N)", color="#888", fontsize=8)
    ax.loglog(xx, base * xx ** 2 / 8, color="#888", linestyle=":", linewidth=0.8)
    ax.text(64, base * 64 ** 2 / 8 * 1.05, "O(N²)", color="#888", fontsize=8)

    ax.set_xlabel("N (NUM_PORTS / NUM_BANKS)")
    ax.set_ylabel("overhead area (µm²)")
    ax.set_title("Effective interconnect overhead vs N\n"
                 "(solid = cell; dotted = + PnR whitespace; dashed = xbar-only)")
    ax.legend(loc="upper left", framealpha=0.95, fontsize=8)
    ax.grid(True, which="both", alpha=0.3)
    ax.set_axisbelow(True)

    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig3_scaling.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig3_scaling.{png,pdf}")


def load_routing():
    """Return dict {(design, label): {col -> float}} from routing.csv."""
    out = {}
    path = HERE / "routing.csv"
    if not path.exists():
        return out
    with path.open() as f:
        for r in csv.DictReader(f):
            key = (r["design"], r["label"])
            out[key] = {
                "n":            int(float(r["n"])),
                "util":         float(r["util"]),
                "core_area":    float(r["core_area"]),
                "cell_area":    float(r["cell_area"]),
                "macro_area":   float(r["macro_area"]),
                "overflow":     float(r["overflow"]),
                "overflow_pct": float(r["overflow_pct"]),
                "wirelength":   float(r["wirelength"]),
            }
    return out


def fig4_routing(rt):
    series = {
        "VX_local_mem_top": ("LMEM",      ["L1", "L2", "L3", "L4"], "#3a7ca5", "o"),
        "VX_cache_top":     ("DCACHE",    ["C1", "C2", "C3", "C4"], "#d9774a", "s"),
        "VX_axi_adapter":   ("AXI adapter", ["A1", "A2", "A3", "A4"], "#5a8a3b", "^"),
    }

    fig, (axU, axC) = plt.subplots(1, 2, figsize=(13, 4.6))
    for design, (name, labels, color, marker) in series.items():
        ns, utils, ovfs = [], [], []
        for lb in labels:
            r = rt.get((design, lb))
            if not r or r["util"] == 0.0:  # skip missing/half-written reports
                continue
            ns.append(r["n"])
            utils.append(r["util"])
            ovfs.append(r["overflow_pct"])
        if not ns:
            continue
        axU.plot(ns, utils, marker=marker, color=color, label=name, linewidth=1.7, markersize=7)
        axC.plot(ns, ovfs,  marker=marker, color=color, label=name, linewidth=1.7, markersize=7)

    # gemm_unit reference (single point, plotted as a horizontal band)
    g = rt.get(("VX_gemm_unit_top", "WKQ"))
    if g and g["util"] > 0:
        axU.axhline(g["util"], color="#444", linestyle="--", linewidth=1.0,
                    label=f"VX_gemm_unit (util={g['util']:.2f})")
        if g["overflow_pct"] > 0:
            axC.axhline(g["overflow_pct"], color="#444", linestyle="--", linewidth=1.0,
                        label=f"VX_gemm_unit (ovf={g['overflow_pct']:.2f}%)")

    axU.set_xscale("log", base=2)
    axU.set_xlabel("N (NUM_PORTS / NUM_BANKS)")
    axU.set_ylabel("Core utilization (cells / core area)")
    axU.set_title("Utilization — DC auto-spreads cells when routing tightens\n"
                  "(↓ = harder to route)")
    axU.set_ylim(0, max(0.7, axU.get_ylim()[1]))
    axU.legend(loc="lower left", fontsize=9, framealpha=0.95)
    axU.grid(True, which="both", alpha=0.3)
    axU.set_axisbelow(True)

    axC.set_xscale("log", base=2)
    axC.set_xlabel("N (NUM_PORTS / NUM_BANKS)")
    axC.set_ylabel("Zroute residual overflow (% of GRCs)")
    axC.set_title("Congestion overflow — direct routing-pain proxy\n"
                  "(↑ = harder to route)")
    axC.legend(loc="upper left", fontsize=9, framealpha=0.95)
    axC.grid(True, which="both", alpha=0.3)
    axC.set_axisbelow(True)

    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig4_routing_proxies.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig4_routing_proxies.{png,pdf}")


# --- Constants used by fig7 / fig8 ------------------------------------------
F_HZ = 1e8                       # 100 MHz target
GEMM32_TOTAL_UM2 = 868874.40     # VX_gemm_unit_top WKQ, N=32
GEMM32_MXU_UM2   = 470610.73     # u_mxu (PE array)  @ N=32


# --- fig7: baseline (16x16 FP16xFP16) vs FPxINT (32x32 FP16xINT4) ---------
# Three area sets (cumulative): gemm only / +xbar+ctrl / +SRAM peri.
# Each candidate has its own bandwidth-matched memory subsystem.
# (FP_MULT_FP16 etc. match analysis_workspace/arr_level_comparison/scale_array_size.py)
FP_MULT_FP16     = 899.144987   # µm² per FP16 mult
FP_ADDSUB_FP32   = 1004.44498   # µm² per FP32 add/sub (for accumulator tree)
FP_FLT2I_FP16    = 205.568998   # µm² per FP16 flt2i (output cast)

FIG7_BASE  = {"name": "Baseline\n16×16 FP16×FP16", "N": 16, "kind": "fpfp",
              "L": "L2", "C": "C0", "A": "A0", "color": "#888888"}
FIG7_FPINT = {"name": "FPxINT\n32×32 FP16×INT4", "N": 32, "kind": "fpint",
              "L": "L4", "C": "C2", "A": "A2", "color": "#d9774a"}


def _gemm_area_any(n, kind):
    if kind == "fpfp":
        return n*n*FP_MULT_FP16 + n*(n-1)*FP_ADDSUB_FP32 + n*FP_FLT2I_FP16
    # fpint: scale from synthesized N=32 by u_mxu ∝ N², rest ∝ N
    s = n / 32.0
    rest = GEMM32_TOTAL_UM2 - GEMM32_MXU_UM2
    return GEMM32_MXU_UM2 * s * s + rest * s


def _charges_sram_peri(scn) -> bool:
    """SRAM peri is bank-scaling overhead; charge it only to FPxINT cases."""
    return scn["kind"] != "fpfp"


def _sram_peri_for(scn, *mems) -> float:
    if not _charges_sram_peri(scn):
        return 0.0
    return sum(m["sram_peri"] for m in mems)


def _fig7_components(scn, s_split):
    L = s_split[scn["L"]]; C = s_split[scn["C"]]; A = s_split[scn["A"]]
    g = _gemm_area_any(scn["N"], scn["kind"])
    xc = (L["xbar"] + L["ctrl"]) + (C["xbar"] + C["ctrl"]) + (A["xbar"] + A["ctrl"])
    peri = _sram_peri_for(scn, L, C)   # AXI has no SRAM
    return g, xc, peri


def _pnr_full_die(scn, s_split, routing, exclude_sram_base=False):
    """Sum of per-component full die area = cell_i / util_i.
    Includes SRAM baseline (since macros are part of the placed cells) and the
    PnR whitespace that DC reserves for routability.
    When `exclude_sram_base` is True, the CAP-intrinsic SRAM bit-cell area is
    dropped from cell_i so Set 4 only reflects logic/peri + PnR overhead."""
    L = s_split[scn["L"]]; C = s_split[scn["C"]]; A = s_split[scn["A"]]
    g_cell = _gemm_area_any(scn["N"], scn["kind"])
    sb = 0.0 if exclude_sram_base else 1.0
    sp = 1.0 if _charges_sram_peri(scn) else 0.0
    L_cell = L["xbar"] + L["ctrl"] + sb * L["sram_base"] + sp * L["sram_peri"]
    C_cell = C["xbar"] + C["ctrl"] + sb * C["sram_base"] + sp * C["sram_peri"]
    A_cell = A["xbar"] + A["ctrl"] + sb * A["sram_base"] + sp * A["sram_peri"]
    uL = routing[("VX_local_mem_top", scn["L"])]["util"]
    uC = routing[("VX_cache_top",     scn["C"])]["util"]
    uA = routing[("VX_axi_adapter",   scn["A"])]["util"]
    return (g_cell / UTIL_GEMM
            + L_cell / uL
            + C_cell / uC
            + A_cell / uA)


def fig7_tops_per_mm2_3set(table):
    s = split_sram(table)
    routing = load_routing()
    g_b, xc_b, peri_b = _fig7_components(FIG7_BASE,  s)
    g_f, xc_f, peri_f = _fig7_components(FIG7_FPINT, s)
    # gemm area always includes its own PnR overhead.
    g_b_die = g_b / UTIL_GEMM
    g_f_die = g_f / UTIL_GEMM
    die_b = _pnr_full_die(FIG7_BASE,  s, routing, exclude_sram_base=True)
    die_f = _pnr_full_die(FIG7_FPINT, s, routing, exclude_sram_base=True)

    tops_b = FIG7_BASE ["N"]**2 * 2 * F_HZ / 1e12
    tops_f = FIG7_FPINT["N"]**2 * 2 * F_HZ / 1e12

    sets_b = [g_b_die/1e6, (g_b_die+xc_b)/1e6, (g_b_die+xc_b+peri_b)/1e6, die_b/1e6]
    sets_f = [g_f_die/1e6, (g_f_die+xc_f)/1e6, (g_f_die+xc_f+peri_f)/1e6, die_f/1e6]
    eff_b  = [tops_b / a for a in sets_b]
    eff_f  = [tops_f / a for a in sets_f]
    ratio  = [f/b for f, b in zip(eff_f, eff_b)]

    set_names = ["Set 1\ngemm only\n(w/ PnR)",
                 "Set 2\n+ xbar + ctrl",
                 "Set 3\n+ SRAM peri\n(FPxINT only)",
                 "Set 4\n+ memory system PnR\n(full die)"]
    x = np.arange(4)
    width = 0.36

    fig, ax = plt.subplots(figsize=(12, 5.8))
    bars_b = ax.bar(x - width/2, eff_b, width, color=FIG7_BASE ["color"],
                    label="Baseline (16×16 FP16×FP16)", edgecolor="black", linewidth=0.5)
    bars_f = ax.bar(x + width/2, eff_f, width, color=FIG7_FPINT["color"],
                    label="FPxINT (32×32 FP16×INT4)",    edgecolor="black", linewidth=0.5)

    ax.set_yscale("log")
    ymin = min(eff_b + eff_f) * 0.3
    ymax = max(eff_b + eff_f) * 4.0
    ax.set_ylim(ymin, ymax)

    # value labels above bars
    for bb, v in list(zip(bars_b, eff_b)) + list(zip(bars_f, eff_f)):
        ax.text(bb.get_x() + bb.get_width()/2, v * 1.10,
                f"{v:.4f}", ha="center", fontsize=8.5, color="#222")
    # area in-bar (use log midpoint)
    for bb, a in list(zip(bars_b, sets_b)) + list(zip(bars_f, sets_f)):
        ax.text(bb.get_x() + bb.get_width()/2, bb.get_height() * 0.55,
                f"{a:.2f}\nmm²", ha="center", va="center",
                fontsize=8, color="white", fontweight="bold")
    # ratio above each group (near top of log axis)
    top_y = ymax * 0.7
    for i, r in enumerate(ratio):
        ax.text(x[i], top_y,
                f"FPxINT / Base\n= {r:.2f}×",
                ha="center", fontsize=10, fontweight="bold",
                color="#3a5c25" if r >= 1.5 else "#666",
                bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="#aaa", alpha=0.9))

    ax.set_xticks(x)
    ax.set_xticklabels(set_names, fontsize=9)
    ax.set_ylabel("TOPS / mm²   (log scale; 100 MHz, 28LPP)")
    ax.set_title("TOPS/mm² across four cumulative area sets: gemm → overhead → full die",
                 fontsize=11)
    ax.legend(loc="lower left", fontsize=10, framealpha=0.95)
    ax.yaxis.grid(True, which="both", alpha=0.3)
    ax.set_axisbelow(True)

    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig7_tops_baseline_vs_fpint.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig7_tops_baseline_vs_fpint.{png,pdf}")


# --- fig8: TOPS/mm² recovery with low-overhead interconnect scaling -----
# Three variants share the same plot layout. Each defines a (BASE, FPINT) array
# pair and the bank/port counts to use for each (via the rule L=N²/16,
# D=A=max(1, N²/128)). Memory points outside the synthesized labels (L > 64 or
# below the minimum labels) are log-log extrapolated from the existing trend.
LABELS_PER_TOP = {
    "VX_local_mem_top": [("L1", 8), ("L2", 16), ("L3", 32), ("L4", 64)],
    "VX_cache_top":     [("C0", 2), ("C1", 4),  ("C2", 8),  ("C3", 16), ("C4", 32)],
    "VX_axi_adapter":   [("A0", 2), ("A1", 4),  ("A2", 8),  ("A3", 16), ("A4", 32)],
}


def _mem_data(top: str, n_target: int, s_split, routing):
    """Return memory cell breakdown + util at a given bank/port count.
    Looks up synthesized data when n_target matches a label; otherwise fits
    log-log linear trends per component (xbar, ctrl, sram_base, sram_peri)
    and a linear-in-log-N trend for util, then evaluates at n_target.
    """
    pairs = LABELS_PER_TOP[top]
    by_n = {n: lb for lb, n in pairs}
    if n_target in by_n:
        lb = by_n[n_target]
        d = s_split[lb]
        return {
            "xbar": d["xbar"], "ctrl": d["ctrl"],
            "sram_base": d["sram_base"], "sram_peri": d["sram_peri"],
            "util": routing[(top, lb)]["util"],
            "extrap": False, "label": lb,
        }
    ns = np.array([n for _, n in pairs], dtype=float)
    xs = np.log(ns)
    target = np.log(float(n_target))

    def _fit_loglog(ys):
        arr = np.asarray(ys, dtype=float)
        mask = arr > 0
        if mask.sum() < 2:
            return float(arr[mask][0]) if mask.any() else 0.0
        coef = np.polyfit(xs[mask], np.log(arr[mask]), 1)
        return float(np.exp(np.polyval(coef, target)))

    xbar = _fit_loglog([s_split[lb]["xbar"]      for lb, _ in pairs])
    ctrl = _fit_loglog([s_split[lb]["ctrl"]      for lb, _ in pairs])
    sb   = _fit_loglog([s_split[lb]["sram_base"] for lb, _ in pairs])
    sp_vals = [s_split[lb]["sram_peri"] for lb, _ in pairs]
    sp   = _fit_loglog(sp_vals) if any(v > 0 for v in sp_vals) else 0.0
    utils = np.array([routing[(top, lb)]["util"] for lb, _ in pairs])
    ucoef = np.polyfit(xs, utils, 1)
    util = float(np.polyval(ucoef, target))
    util = max(0.10, min(0.95, util))
    return {"xbar": xbar, "ctrl": ctrl, "sram_base": sb, "sram_peri": sp,
            "util": util, "extrap": True, "label": f"~{n_target}"}


def _bank_port_counts(N: int):
    """L = N²/16, D = A = max(1, N²/128)."""
    return N * N // 16, max(1, N * N // 128), max(1, N * N // 128)


def _variant_components(scn, s_split, routing):
    """Return (gemm_die, xc, peri, full_die, mems) for one scenario dict.
    `scn` must carry N, kind, L_n, C_n, A_n.
    """
    g = _gemm_area_any(scn["N"], scn["kind"])
    g_die = g / UTIL_GEMM
    L = _mem_data("VX_local_mem_top", scn["L_n"], s_split, routing)
    C = _mem_data("VX_cache_top",     scn["C_n"], s_split, routing)
    A = _mem_data("VX_axi_adapter",   scn["A_n"], s_split, routing)
    xc   = (L["xbar"] + L["ctrl"]) + (C["xbar"] + C["ctrl"]) + (A["xbar"] + A["ctrl"])
    peri = _sram_peri_for(scn, L, C)   # AXI has no SRAM
    # Set 4 (memory full die, CAP-intrinsic SRAM excluded):
    sp = 1.0 if _charges_sram_peri(scn) else 0.0
    L_cell = L["xbar"] + L["ctrl"] + sp * L["sram_peri"]
    C_cell = C["xbar"] + C["ctrl"] + sp * C["sram_peri"]
    A_cell = A["xbar"] + A["ctrl"] + sp * A["sram_peri"]
    full_die = g_die + L_cell / L["util"] + C_cell / C["util"] + A_cell / A["util"]
    return g_die, xc, peri, full_die, (L, C, A)


def _variant_bars_data(variant, table, routing):
    """Compute everything needed to draw one variant's two-bar group on a subplot."""
    s = split_sram(table)
    base  = variant["base"]
    fpint = variant["fpint"]
    g_b_die, xc_b, peri_b, die_b, (Lb, Cb, Ab) = _variant_components(base,  s, routing)
    g_f_die, xc_f, peri_f, die_f, (Lf, Cf, Af) = _variant_components(fpint, s, routing)
    tops_b = base ["N"]**2 * 2 * F_HZ / 1e12
    tops_f = fpint["N"]**2 * 2 * F_HZ / 1e12
    sets_b = [g_b_die/1e6, (g_b_die+xc_b)/1e6, (g_b_die+xc_b+peri_b)/1e6, die_b/1e6]
    sets_f = [g_f_die/1e6, (g_f_die+xc_f)/1e6, (g_f_die+xc_f+peri_f)/1e6, die_f/1e6]
    eff_b = [tops_b / a for a in sets_b]
    eff_f = [tops_f / a for a in sets_f]

    def _mem_label(L, C, A, ln, cn, an):
        return f"L={ln} / D={cn} / A={an}"

    return {
        "base_n": base["N"], "fpint_n": fpint["N"],
        "rel_b": [1.0] * 4,
        "rel_f": [eff_f[i] / eff_b[i] for i in range(4)],
        "sets_b": sets_b, "sets_f": sets_f,
        "base_mem":  _mem_label(Lb, Cb, Ab, base["L_n"],  base["C_n"],  base["A_n"]),
        "fpint_mem": _mem_label(Lf, Cf, Af, fpint["L_n"], fpint["C_n"], fpint["A_n"]),
    }


def _draw_variant_on_axis(ax, d, ymax):
    """Draw a 2-bar group (Base vs FPxINT) for one variant on a given axis."""
    x = np.arange(4)
    width = 0.36
    set_names = ["Set 1\ngemm only\n(w/ PnR)",
                 "Set 2\n+ xbar + ctrl",
                 "Set 3\n+ SRAM peri\n(FPxINT only)",
                 "Set 4\n+ memory system PnR\n(full die)"]

    bars_b = ax.bar(x - width/2, d["rel_b"], width, color="#888888",
                    edgecolor="black", linewidth=0.5,
                    label=f"Baseline ({d['base_n']}×{d['base_n']} FP16×FP16; {d['base_mem']})")
    bars_f = ax.bar(x + width/2, d["rel_f"], width, color="#3a7ca5",
                    edgecolor="black", linewidth=0.5,
                    label=f"FPxINT ({d['fpint_n']}×{d['fpint_n']} FP16×INT4; {d['fpint_mem']})")

    ax.set_ylim(0, ymax)
    ax.axhline(1.0, color="#444", linestyle="--", linewidth=0.8, alpha=0.7)

    for bb, v in list(zip(bars_b, d["rel_b"])) + list(zip(bars_f, d["rel_f"])):
        ax.text(bb.get_x() + bb.get_width()/2, v + ymax * 0.015,
                f"{v:.2f}×", ha="center", fontsize=9, color="#222", fontweight="bold")
    for bb, a in list(zip(bars_b, d["sets_b"])) + list(zip(bars_f, d["sets_f"])):
        ax.text(bb.get_x() + bb.get_width()/2, bb.get_height() * 0.5,
                f"{a:.2f}\nmm²", ha="center", va="center",
                fontsize=8, color="white", fontweight="bold")

    # MXU-size badge in the top-left of the subplot.
    ax.text(0.012, 0.97,
            f"{d['base_n']}×{d['base_n']} FPxFP VS "
            f"{d['fpint_n']}×{d['fpint_n']} FPxINT",
            transform=ax.transAxes, ha="left", va="top",
            fontsize=11, fontweight="bold", color="#222",
            bbox=dict(boxstyle="round,pad=0.35", fc="#fff8e0", ec="#aaa", alpha=0.95))

    ax.set_xticks(x)
    ax.set_xticklabels(set_names, fontsize=8.5)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.16),
              ncol=1, fontsize=8.5, framealpha=0.95)


FIG8_VARIANTS = [
    {
        "fname": "fig8a_tops_recovery_base16_fpint32",
        "title": "BASE 16×16 FPFP vs FPINT 32×32 (existing)",
        "base":  {"N": 16, "kind": "fpfp",
                  "L_n": 16, "C_n": 2,  "A_n": 2},
        "fpint": {"N": 32, "kind": "fpint",
                  "L_n": 64, "C_n": 8,  "A_n": 8},
    },
    {
        "fname": "fig8b_tops_recovery_base32_fpint64",
        "title": "BASE 32×32 FPFP vs FPINT 64×64",
        "base":  {"N": 32, "kind": "fpfp",
                  "L_n": 64,  "C_n": 8,  "A_n": 8},
        "fpint": {"N": 64, "kind": "fpint",
                  "L_n": 256, "C_n": 32, "A_n": 32},
    },
]


def fig8_tops_recovery_all(table):
    routing = load_routing()
    datas = [_variant_bars_data(v, table, routing) for v in FIG8_VARIANTS]
    # Shared y-axis for fair visual comparison across subplots.
    ymax = max(max(d["rel_b"] + d["rel_f"]) for d in datas) * 1.22

    n = len(datas)
    fig, axes = plt.subplots(1, n, figsize=(8.5 * n, 6.3), sharey=True)
    if n == 1:
        axes = [axes]
    for ax, d in zip(axes, datas):
        _draw_variant_on_axis(ax, d, ymax)
    axes[0].set_ylabel("TOPS/mm² (relative to Baseline; per-Set Base = 1.0)\n"
                       "in-bar = absolute area in mm²")

    fig.suptitle("Relative TOPS/mm² across four cumulative area sets",
                 fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    for ext in ("png", "pdf"):
        fig.savefig(HERE / f"fig8_tops_recovery.{ext}", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("wrote fig8_tops_recovery.{png,pdf}")


def main():
    table = load()
    fig1_stacked(table)
    fig2_ratio(table)
    fig3_scaling(table)
    rt = load_routing()
    if rt:
        fig4_routing(rt)
    fig7_tops_per_mm2_3set(table)
    fig8_tops_recovery_all(table)


if __name__ == "__main__":
    main()
