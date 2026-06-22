"""Stacked-bar area breakdown of synthesized Vortex_axi.

Parses the DC topographical area report with hwexplorer and emits a single
stacked bar that decomposes Vortex_axi cell area into the meaningful
sub-blocks (gemm_node / mem_unit / caches / AXI infra / ...). The breakdown
deliberately reaches inside `vortex/cluster/socket/core` since the top-level
hierarchy is 99.6% `vortex` and not informative on its own.

Run from a Python with hwexplorer installed (e.g. `conda activate stable`):

    python analysis_workspace/top_breakdown/breakdown.py

Defaults to the NT32 synthesis run. Use `--run nt8` to regenerate the NT8
breakdown.

Outputs (under analysis_workspace/top_breakdown/<run>/):
    vortex_axi_breakdown.csv  - per-bucket area table
    vortex_axi_breakdown.png  - stacked bar figure
    vortex_axi_breakdown.pdf  - same, vector
    vortex_axi_breakdown_pie.png  - pie/donut chart figure
    vortex_axi_breakdown_pie.pdf  - same, vector
    vortex_axi_breakdown_pie.svg  - same, vector
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from hwexplorer.report_parser import SynopsysDesignCompilerAreaParser

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]

BLUE_DARK = "#0f4c81"
BLUE = "#2f80b7"
BLUE_LIGHT = "#6baed6"
BLUE_PALE = "#9ecae1"
TEAL = "#147d8f"
TEAL_LIGHT = "#41b6c4"
GREEN_DARK = "#1b7837"
GREEN = "#2ca25f"
GREEN_LIGHT = "#74c476"
GREEN_PALE = "#a1d99b"
GRAY = "#8a8f96"

plt.rcParams.update({
    "font.size": 14,
    "axes.titlesize": 16,
    "axes.labelsize": 15,
    "xtick.labelsize": 13,
    "ytick.labelsize": 13,
    "legend.fontsize": 12,
    "figure.titlesize": 17,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
    "svg.fonttype": "none",
})

RUNS = {
    "nt8": {
        "syn_dir": "Vortex_axi",
        "title": "NT8",
    },
    "nt32": {
        "syn_dir": "Vortex_axi_nt32",
        "title": "NT32",
    },
}

# Bucket = (label, list of full_path regexes).
# Patterns are matched against `full_path` in the hierarchy DataFrame; each
# matched row is consumed at most once (longest/first-listed pattern wins),
# so the order matters and the sum is double-count free.
#
# Bottom-up order in the stack: core internals first, then per-socket caches,
# then per-cluster / per-chip caches, then AXI memory plumbing.
PREFIX_CORE = (
    r"^Vortex_axi/vortex/g_clusters_\d+__cluster/"
    r"g_sockets_\d+__socket/g_cores_\d+__core"
)
PREFIX_GEMM_NODE = PREFIX_CORE + r"/gemm_node"
PREFIX_TMEM = PREFIX_GEMM_NODE + r"/u_tmem_subsystem"
PREFIX_SOCKET = (
    r"^Vortex_axi/vortex/g_clusters_\d+__cluster/g_sockets_\d+__socket"
)
PREFIX_CLUSTER = r"^Vortex_axi/vortex/g_clusters_\d+__cluster"

# `gemm_node` is split into its direct children. Inside `u_tmem_subsystem`
# we go one level deeper to separate the tensor-mem banks (SRAM-dominated)
# from the DMA engines and the small local DMAs / switches around them.
BREAKDOWN: list[tuple[str, list[str]]] = [
    # --- gemm_node internals ---
    ("GEMM unit (MXU compute)",      [PREFIX_GEMM_NODE + r"/u_VX_gemm_unit$"]),
    ("TMEM banks (tensor memory SRAM)",
                                     [PREFIX_TMEM + r"/g_bank_\d+__u_bank$"]),
    ("TMEM DMA engine",              [PREFIX_TMEM + r"/u_dma_engine$"]),
    ("TMEM local DMAs",              [PREFIX_TMEM + r"/u_ldma_(input|output|sz|weight)$"]),
    ("TMEM switches",                [PREFIX_TMEM + r"/u_switch_(input|output)$"]),
    ("GEMM control + TMEM DMA control + job frontend",
                                     [PREFIX_GEMM_NODE + r"/u_VX_gemm_ctrl$",
                                      PREFIX_GEMM_NODE + r"/u_tmem_dma_ctrl$",
                                      PREFIX_GEMM_NODE + r"/u_job_frontend$"]),
    # --- rest of core ---
    ("memory unit",                  [PREFIX_CORE + r"/mem_unit$"]),
    ("execute",                      [PREFIX_CORE + r"/execute$"]),
    ("issue",                        [PREFIX_CORE + r"/issue$"]),
    ("schedule",                     [PREFIX_CORE + r"/schedule$"]),
    ("DMA node",                     [PREFIX_CORE + r"/u_VX_dma_node$"]),
    ("fetch / commit / decode / DCR",
                                     [PREFIX_CORE + r"/(fetch|commit|decode|dcr_data)$"]),
    # --- socket / cluster / chip caches ---
    ("L1 data cache",                [PREFIX_SOCKET + r"/dcache$"]),
    ("L1 instruction cache",         [PREFIX_SOCKET + r"/icache$"]),
    ("socket memory arbiter",
                                     [PREFIX_SOCKET + r"/g_mem_bus_if_\d+__g_i\d+_mem_arb$"]),
    ("L2 cache",                     [PREFIX_CLUSTER + r"/l2cache$"]),
    ("L3 cache",                     [r"^Vortex_axi/vortex/l3cache$"]),
    # --- AXI memory plumbing outside vortex ---
    ("HBM AXI mux x8",               [r"^Vortex_axi/g_hbm_mux_\d+__u_axi_mux$"]),
    ("LSU demux",                    [r"^Vortex_axi/u_lsu_demux$"]),
    ("AXI adapter / memory adapter / remaps",
                                     [r"^Vortex_axi/axi_adapter$",
                                      r"^Vortex_axi/g_mem_adapter_\d+__mem_data_adapter$",
                                      r"^Vortex_axi/u_lsu_(ar|aw)_remap$"]),
]

# Blue/green family for paper consistency. Sibling shades stay close.
COLORS = {
    # gemm_node compute
    "GEMM unit (MXU compute)":               BLUE_DARK,
    # gemm_node memory side
    "TMEM banks (tensor memory SRAM)":        BLUE,
    "TMEM DMA engine":                        BLUE_LIGHT,
    "TMEM local DMAs":                        BLUE_PALE,
    "TMEM switches":                          TEAL_LIGHT,
    "GEMM control + TMEM DMA control + job frontend":
                                             TEAL,
    # rest of core
    "memory unit":                           GREEN_DARK,
    "execute":                               GREEN,
    "issue":                                 GREEN_LIGHT,
    "schedule":                              GREEN_PALE,
    "DMA node":                              TEAL,
    "fetch / commit / decode / DCR":         TEAL_LIGHT,
    # caches
    "L1 data cache":                         BLUE_PALE,
    "L1 instruction cache":                  BLUE_LIGHT,
    "socket memory arbiter":                 BLUE,
    "L2 cache":                              BLUE_DARK,
    "L3 cache":                              "#063b66",
    # AXI plumbing
    "HBM AXI mux x8":                        GREEN_PALE,
    "LSU demux":                             GREEN_LIGHT,
    "AXI adapter / memory adapter / remaps": GREEN,
    "Other":                                 GRAY,
}

MISC_LABEL = "misc (interconnection + mux/demux)"
FORCE_MISC_LABELS = {
    "HBM AXI mux x8",
    "LSU demux",
}
PIN_TO_TOP_LABELS = [
    "TMEM DMA engine",
    "TMEM local DMAs",
    "GEMM control + TMEM DMA control + job frontend",
    MISC_LABEL,
]


def aggregate(hdf: pd.DataFrame) -> tuple[dict[str, float], dict[str, int], list[str]]:
    """Sum global area per bucket. A row is consumed by the first matching bucket."""
    sums: dict[str, float] = {label: 0.0 for label, _ in BREAKDOWN}
    counts: dict[str, int] = {label: 0 for label, _ in BREAKDOWN}
    matched_rows = set()
    for label, patterns in BREAKDOWN:
        rxs = [re.compile(p) for p in patterns]
        for idx, fp in hdf["full_path"].items():
            if idx in matched_rows:
                continue
            if any(rx.match(fp) for rx in rxs):
                sums[label] += float(hdf.at[idx, "area"])
                counts[label] += 1
                matched_rows.add(idx)
    return sums, counts, sorted(matched_rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Vortex_axi top-level area breakdown."
    )
    parser.add_argument(
        "--run",
        choices=RUNS.keys(),
        default="nt32",
        help="Synthesis run to analyze. Default: nt32.",
    )
    return parser.parse_args()


def bucket_color(label: str) -> str:
    if label.startswith("misc"):
        return GRAY
    return COLORS.get(label, GRAY)


def pin_selected_labels_to_top(
    sums: dict[str, float],
    counts: dict[str, int],
) -> tuple[dict[str, float], dict[str, int]]:
    ordered_labels = [
        label for label in PIN_TO_TOP_LABELS
        if label in sums
    ] + [
        label for label in sums
        if label not in PIN_TO_TOP_LABELS
    ]
    return (
        {label: sums[label] for label in ordered_labels},
        {label: counts[label] for label in ordered_labels},
    )


def main():
    args = parse_args()
    run = RUNS[args.run]
    rpt = (
        VORTEX
        / "build/hw/syn/synopsys"
        / run["syn_dir"]
        / "syn_topo.lpp/reports/14_Vortex_axi.mapped.area.rpt"
    )
    out_dir = HERE / args.run
    out_dir.mkdir(parents=True, exist_ok=True)

    parser = SynopsysDesignCompilerAreaParser()
    db = parser.load(str(rpt))
    if db.HIERARCHY_KEY not in db.tables:
        raise SystemExit(f"hierarchy table missing in {rpt}")
    hdf = db.tables[db.HIERARCHY_KEY]
    total_area = float(db.metadata["total_cell_area"])

    sums, counts, _ = aggregate(hdf)

    captured = sum(sums.values())
    other = max(0.0, total_area - captured)
    sums["Other"] = other
    counts["Other"] = 0

    # Collapse buckets below MISC_THRESHOLD mm² into a single "misc" entry so
    # the legend stays readable. Order is preserved: the misc bucket lands at
    # the position where the first absorbed item was.
    MISC_THRESHOLD_UM2 = 0.01 * 1e6  # 0.01 mm² = 10 000 µm²
    misc_sum = 0.0
    misc_count = 0
    misc_members: list[str] = []
    misc_position: int | None = None
    new_sums: dict[str, float] = {}
    new_counts: dict[str, int] = {}
    for i, (label, area) in enumerate(sums.items()):
        if area < MISC_THRESHOLD_UM2 or label in FORCE_MISC_LABELS:
            if misc_position is None:
                misc_position = len(new_sums)
            misc_sum += area
            misc_count += counts[label]
            misc_members.append(label)
        else:
            new_sums[label] = area
            new_counts[label] = counts[label]
    if misc_members:
        items = list(new_sums.items())
        count_items = list(new_counts.items())
        items.insert(misc_position, (MISC_LABEL, misc_sum))
        count_items.insert(misc_position, (MISC_LABEL, misc_count))
        sums = dict(items)
        counts = dict(count_items)
        print(f"\nmisc bucket absorbs: {', '.join(misc_members)}")
    else:
        sums = new_sums
        counts = new_counts
    sums, counts = pin_selected_labels_to_top(sums, counts)

    labels = list(sums.keys())
    areas_um2 = [sums[l] for l in labels]
    areas_mm2 = [a / 1e6 for a in areas_um2]
    pcts = [a / total_area * 100 for a in areas_um2]

    df_out = pd.DataFrame({
        "module":      labels,
        "num_matched": [counts[l] for l in labels],
        "area_um2":    areas_um2,
        "area_mm2":    areas_mm2,
        "percent":     pcts,
    })
    csv_path = out_dir / "vortex_axi_breakdown.csv"
    df_out.to_csv(csv_path, index=False)
    print(df_out.to_string(index=False, float_format=lambda v: f"{v:10.4f}"))
    print(f"\nTotal cell area: {total_area/1e6:.3f} mm² (sum of buckets = {sum(areas_mm2):.3f} mm²)")
    print(f"source report: {rpt}")
    print(f"wrote {csv_path}")

    # ---- stacked bar ----
    fig, ax = plt.subplots(figsize=(9.5, 10.8))
    bottom = 0.0
    total_mm2 = sum(areas_mm2)
    handles = []
    for label, val_mm2, pct in zip(labels, areas_mm2, pcts):
        color = bucket_color(label)
        ax.bar(0, val_mm2, bottom=bottom, color=color,
               edgecolor="black", linewidth=0.4, width=1.0)
        if pct >= 3.0:
            short = label.split(" (")[0]
            ax.text(0, bottom + val_mm2 / 2,
                    f"{short}\n{val_mm2:.2f} mm²  ({pct:.1f}%)",
                    ha="center", va="center", fontsize=12,
                    color="white" if pct >= 8 else "#111")
        handles.append(plt.Rectangle((0, 0), 1, 1, fc=color,
                                     label=f"{label}: {val_mm2:.2f} mm² ({pct:.1f}%)",
                                     edgecolor="black", linewidth=0.4))
        bottom += val_mm2

    ax.set_xticks([])
    ax.set_xlim(-0.8, 0.8)
    ax.set_ylabel("Cell area (mm²)")
    ax.set_title(
        # f"Vortex_axi {run['title']} area breakdown\n"
        # f"Area breakdown\n"
        f"DC topo, Samsung 28LPP — total cell area = {total_mm2:.2f} mm²",
        fontsize=16,
    )
    ax.legend(handles=handles, loc="center left", bbox_to_anchor=(1.02, 0.5),
              fontsize=12, framealpha=0.95, handlelength=1.2)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)

    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = out_dir / f"vortex_axi_breakdown.{ext}"
        fig.savefig(p, dpi=300, bbox_inches="tight")
        print(f"wrote {p}")
    plt.close(fig)

    # ---- pie / donut chart ----
    pie_colors = [bucket_color(label) for label in labels]

    def pct_label(pct: float) -> str:
        return f"{pct:.1f}%" if pct >= 2.0 else ""

    fig, ax = plt.subplots(figsize=(12.5, 9.2))
    wedges, _, autotexts = ax.pie(
        areas_mm2,
        colors=pie_colors,
        startangle=90,
        counterclock=False,
        autopct=pct_label,
        pctdistance=0.78,
        wedgeprops={
            "width": 0.52,
            "edgecolor": "white",
            "linewidth": 0.8,
        },
    )
    for text in autotexts:
        text.set_fontsize(12)
        text.set_fontweight("bold")

    ax.text(
        0,
        0,
        f"{total_mm2:.2f} mm²",
        ha="center",
        va="center",
        fontsize=18,
        fontweight="bold",
    )
    legend_labels = [
        f"{label}: {val_mm2:.2f} mm² ({pct:.1f}%)"
        for label, val_mm2, pct in zip(labels, areas_mm2, pcts)
    ]
    ax.legend(
        wedges,
        legend_labels,
        loc="center left",
        bbox_to_anchor=(1.02, 0.5),
        fontsize=12,
        framealpha=0.95,
    )
    ax.set_aspect("equal")

    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        p = out_dir / f"vortex_axi_breakdown_pie.{ext}"
        fig.savefig(p, dpi=300, bbox_inches="tight")
        print(f"wrote {p}")
    plt.close(fig)


if __name__ == "__main__":
    main()
