"""Stacked-bar area breakdown of synthesized Vortex_axi.

Parses the DC topographical area report with hwexplorer and emits a single
stacked bar that decomposes Vortex_axi cell area into the meaningful
sub-blocks (gemm_node / mem_unit / caches / AXI infra / ...). The breakdown
deliberately reaches inside `vortex/cluster/socket/core` since the top-level
hierarchy is 99.6% `vortex` and not informative on its own.

Run from a Python with hwexplorer installed (e.g. `conda activate stable`):

    python analysis_workspace/top_breakdown/breakdown.py

Outputs (alongside this script):
    vortex_axi_breakdown.csv  - per-bucket area table
    vortex_axi_breakdown.png  - stacked bar figure
    vortex_axi_breakdown.pdf  - same, vector
"""

from __future__ import annotations

import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from hwexplorer.report_parser import SynopsysDesignCompilerAreaParser

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
RPT = (
    VORTEX
    / "build/hw/syn/synopsys/Vortex_axi/syn_topo.lpp"
    / "reports/14_Vortex_axi.mapped.area.rpt"
)

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
    ("gemm_unit (MXU compute)",      [PREFIX_GEMM_NODE + r"/u_VX_gemm_unit$"]),
    ("tmem banks (tensor mem SRAM)", [PREFIX_TMEM + r"/g_bank_\d+__u_bank$"]),
    ("tmem dma_engine",              [PREFIX_TMEM + r"/u_dma_engine$"]),
    ("tmem local DMAs (ldma_*)",     [PREFIX_TMEM + r"/u_ldma_(input|output|sz|weight)$"]),
    ("tmem switches",                [PREFIX_TMEM + r"/u_switch_(input|output)$"]),
    ("gemm_ctrl + tmem_dma_ctrl + job_frontend",
                                     [PREFIX_GEMM_NODE + r"/u_VX_gemm_ctrl$",
                                      PREFIX_GEMM_NODE + r"/u_tmem_dma_ctrl$",
                                      PREFIX_GEMM_NODE + r"/u_job_frontend$"]),
    # --- rest of core ---
    ("mem_unit",                     [PREFIX_CORE + r"/mem_unit$"]),
    ("execute",                      [PREFIX_CORE + r"/execute$"]),
    ("issue",                        [PREFIX_CORE + r"/issue$"]),
    ("schedule",                     [PREFIX_CORE + r"/schedule$"]),
    ("dma_node",                     [PREFIX_CORE + r"/u_VX_dma_node$"]),
    ("fetch / commit / decode / dcr",
                                     [PREFIX_CORE + r"/(fetch|commit|decode|dcr_data)$"]),
    # --- socket / cluster / chip caches ---
    ("L1 dcache",                    [PREFIX_SOCKET + r"/dcache$"]),
    ("L1 icache",                    [PREFIX_SOCKET + r"/icache$"]),
    ("socket mem_arb",
                                     [PREFIX_SOCKET + r"/g_mem_bus_if_\d+__g_i\d+_mem_arb$"]),
    ("L2 cache",                     [PREFIX_CLUSTER + r"/l2cache$"]),
    ("L3 cache",                     [r"^Vortex_axi/vortex/l3cache$"]),
    # --- AXI memory plumbing outside vortex ---
    ("HBM AXI mux x8",               [r"^Vortex_axi/g_hbm_mux_\d+__u_axi_mux$"]),
    ("lsu_demux",                    [r"^Vortex_axi/u_lsu_demux$"]),
    ("axi_adapter / mem_adapter / remaps",
                                     [r"^Vortex_axi/axi_adapter$",
                                      r"^Vortex_axi/g_mem_adapter_\d+__mem_data_adapter$",
                                      r"^Vortex_axi/u_lsu_(ar|aw)_remap$"]),
]

# Reds → gemm compute, browns/yellows → gemm memory & DMA, mustards → core,
# teals → caches, purples → AXI plumbing. Sibling shades stay close.
COLORS = {
    # gemm_node compute
    "gemm_unit (MXU compute)":               "#c4452a",  # deep red-orange
    # gemm_node memory side
    "tmem banks (tensor mem SRAM)":          "#d9774a",  # burnt orange
    "tmem dma_engine":                       "#e8a838",  # gold
    "tmem local DMAs (ldma_*)":              "#f3c969",  # wheat
    "tmem switches":                         "#e6d9a0",  # pale wheat
    "gemm_ctrl + tmem_dma_ctrl + job_frontend":
                                             "#b89860",  # tan
    # rest of core
    "mem_unit":                              "#9aa05a",  # olive
    "execute":                               "#7a8543",  # darker olive
    "issue":                                 "#5a6a3a",  # forest
    "schedule":                              "#465230",  # dark olive
    "dma_node":                              "#8b7b5a",  # taupe
    "fetch / commit / decode / dcr":         "#a4937a",  # warm grey
    # caches
    "L1 dcache":                             "#a4c8c9",  # pale teal
    "L1 icache":                             "#7da8a9",  # teal
    "socket mem_arb":                        "#5a8a8b",  # blue-teal
    "L2 cache":                              "#5a7891",  # dark blue-grey
    "L3 cache":                              "#3a5c75",  # navy
    # AXI plumbing
    "HBM AXI mux x8":                        "#7d6b8c",  # dusty purple
    "lsu_demux":                             "#6a5b7a",  # darker purple
    "axi_adapter / mem_adapter / remaps":    "#5a4d6a",  # deepest purple
    "Other":                                 "#bbbbbb",
}


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


def main():
    parser = SynopsysDesignCompilerAreaParser()
    db = parser.load(str(RPT))
    if db.HIERARCHY_KEY not in db.tables:
        raise SystemExit(f"hierarchy table missing in {RPT}")
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
        if area < MISC_THRESHOLD_UM2:
            if misc_position is None:
                misc_position = len(new_sums)
            misc_sum += area
            misc_count += counts[label]
            misc_members.append(label)
        else:
            new_sums[label] = area
            new_counts[label] = counts[label]
    if misc_members:
        misc_label = f"misc (<0.01 mm²): {len(misc_members)} blocks"
        items = list(new_sums.items())
        count_items = list(new_counts.items())
        items.insert(misc_position, (misc_label, misc_sum))
        count_items.insert(misc_position, (misc_label, misc_count))
        sums = dict(items)
        counts = dict(count_items)
        print(f"\nmisc bucket absorbs: {', '.join(misc_members)}")
    else:
        sums = new_sums
        counts = new_counts

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
    csv_path = HERE / "vortex_axi_breakdown.csv"
    df_out.to_csv(csv_path, index=False)
    print(df_out.to_string(index=False, float_format=lambda v: f"{v:10.4f}"))
    print(f"\nTotal cell area: {total_area/1e6:.3f} mm² (sum of buckets = {sum(areas_mm2):.3f} mm²)")
    print(f"wrote {csv_path}")

    # ---- stacked bar ----
    fig, ax = plt.subplots(figsize=(7.5, 9.5))
    bottom = 0.0
    total_mm2 = sum(areas_mm2)
    handles = []
    for label, val_mm2, pct in zip(labels, areas_mm2, pcts):
        color = "#bbbbbb" if label.startswith("misc (<") else COLORS.get(label, "#999999")
        ax.bar(0, val_mm2, bottom=bottom, color=color,
               edgecolor="black", linewidth=0.4, width=1.0)
        if pct >= 3.0:
            short = label.split(" (")[0]
            ax.text(0, bottom + val_mm2 / 2,
                    f"{short}\n{val_mm2:.2f} mm²  ({pct:.1f}%)",
                    ha="center", va="center", fontsize=9.5,
                    color="white" if pct >= 8 else "#111")
        handles.append(plt.Rectangle((0, 0), 1, 1, fc=color,
                                     label=f"{label}: {val_mm2:.2f} mm² ({pct:.1f}%)",
                                     edgecolor="black", linewidth=0.4))
        bottom += val_mm2

    ax.set_xticks([])
    ax.set_xlim(-0.8, 0.8)
    ax.set_ylabel("Cell area (mm²)")
    ax.set_title(
        f"Vortex_axi area breakdown\n"
        f"DC topo, Samsung 28LPP — total cell area = {total_mm2:.2f} mm²",
        fontsize=11,
    )
    ax.legend(handles=handles, loc="center left", bbox_to_anchor=(1.02, 0.5),
              fontsize=8.5, framealpha=0.95, handlelength=1.2)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)

    fig.tight_layout()
    for ext in ("png", "pdf"):
        p = HERE / f"vortex_axi_breakdown.{ext}"
        fig.savefig(p, dpi=150, bbox_inches="tight")
        print(f"wrote {p}")
    plt.close(fig)


if __name__ == "__main__":
    main()
