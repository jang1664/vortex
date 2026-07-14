"""Stacked-bar area breakdown of synthesized Vortex_axi.

Parses the DC topographical area report with hwexplorer and emits a single
stacked bar that decomposes Vortex_axi cell area into the meaningful
sub-blocks (gemm_node / mem_unit / caches / AXI infra / ...). The breakdown
deliberately reaches inside `vortex/cluster/socket/core` since the top-level
hierarchy is 99.6% `vortex` and not informative on its own.

Run from a Python with plotting dependencies installed (e.g. `conda activate stable`):

    python analysis_workspace/top_breakdown/breakdown.py

Defaults to the current synthesis run (`SYN_RUN_NAME`, or `Vortex_axi` to match
hw/syn/synopsys/run_syn_vortex_axi.py). Use `--run nt32` for the named NT32
run. If the exact run directory is incomplete, the newest valid dated backup
directory is used.

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
import os
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

try:
    from hwexplorer.report_parser import SynopsysDesignCompilerAreaParser
except Exception as exc:  # pragma: no cover - environment-dependent fallback
    SynopsysDesignCompilerAreaParser = None
    HWEXPLORER_IMPORT_ERROR = exc
else:
    HWEXPLORER_IMPORT_ERROR = None

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
DESIGN_NAME = "Vortex_axi"
REPORT_REL = Path("syn_topo.lpp/reports/14_Vortex_axi.mapped.area.rpt")

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
    "current": {
        "syn_dir": os.environ.get("SYN_RUN_NAME", "Vortex_axi"),
        "title": "current",
    },
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
# Bottom-up order in the stack: accelerator / core internals first, then
# per-socket caches, then per-cluster / per-chip caches, then AXI memory
# plumbing.
PREFIX_TOP = rf"^(?:{DESIGN_NAME}/)?"
PREFIX_CORE = (
    PREFIX_TOP
    + r"vortex/g_clusters_\d+__cluster/"
    r"g_sockets_\d+__socket/g_cores_\d+__core"
)
PREFIX_GEMM_NODE = PREFIX_CORE + r"/gemm_node"
PREFIX_TMEM = PREFIX_GEMM_NODE + r"/u_tmem_subsystem"
PREFIX_SOCKET = (
    PREFIX_TOP + r"vortex/g_clusters_\d+__cluster/g_sockets_\d+__socket"
)
PREFIX_CLUSTER = PREFIX_TOP + r"vortex/g_clusters_\d+__cluster"
PREFIX_EXECUTE = PREFIX_CORE + r"/execute"

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
    ("ALU unit",                     [PREFIX_EXECUTE + r"/alu_unit$"]),
    ("LSU unit",                     [PREFIX_EXECUTE + r"/lsu_unit$"]),
    ("FPU unit (FPNEW + HW exp)",    [PREFIX_EXECUTE + r"/fpu_unit$"]),
    ("SFU unit",                     [PREFIX_EXECUTE + r"/sfu_unit$"]),
    ("TCU unit",                     [PREFIX_EXECUTE + r"/tcu_unit$"]),
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
    ("L3 cache",                     [PREFIX_TOP + r"vortex/l3cache$"]),
    # --- AXI memory plumbing outside vortex ---
    ("HBM AXI mux x8",               [PREFIX_TOP + r"g_hbm_mux_\d+__u_axi_mux$"]),
    ("LSU demux",                    [PREFIX_TOP + r"u_lsu_demux$"]),
    ("AXI adapter / memory adapter / remaps",
                                     [PREFIX_TOP + r"axi_adapter$",
                                      PREFIX_TOP + r"g_mem_adapter_\d+__mem_data_adapter$",
                                      PREFIX_TOP + r"u_lsu_(ar|aw)_remap$"]),
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
    "ALU unit":                              GREEN,
    "LSU unit":                              GREEN_LIGHT,
    "FPU unit (FPNEW + HW exp)":             "#7b3294",
    "SFU unit":                              TEAL_LIGHT,
    "TCU unit":                              "#5e3c99",
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
        default="current",
        help="Named synthesis run to analyze. Default: current.",
    )
    parser.add_argument(
        "--syn-root",
        type=Path,
        default=None,
        help="Synthesis result root. Default: SYN_RESULT_ROOT, then build/syn/synopsys with legacy fallback.",
    )
    parser.add_argument(
        "--syn-dir",
        default=None,
        help="Run directory under the synthesis result root. Overrides --run.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=None,
        help="Exact area report path. Overrides --run, --syn-root, and --syn-dir.",
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


def report_is_valid(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return False
    return (
        "Total cell area:" in text
        and "Hierarchical area distribution" in text
    )


def candidate_roots(explicit_root: Path | None) -> list[Path]:
    roots: list[Path] = []
    if explicit_root is not None:
        roots.append(explicit_root)
    elif os.environ.get("SYN_RESULT_ROOT"):
        roots.append(Path(os.environ["SYN_RESULT_ROOT"]))
    else:
        roots.extend([
            VORTEX / "build/syn/synopsys",
            VORTEX / "build/hw/syn/synopsys",
        ])

    deduped: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        resolved = root if root.is_absolute() else VORTEX / root
        if resolved not in seen:
            deduped.append(resolved)
            seen.add(resolved)
    return deduped


def resolve_report(args: argparse.Namespace) -> Path:
    if args.report is not None:
        rpt = args.report if args.report.is_absolute() else VORTEX / args.report
        if not report_is_valid(rpt):
            raise SystemExit(f"area report is missing or incomplete: {rpt}")
        return rpt

    run = RUNS[args.run]
    syn_dir = args.syn_dir or run["syn_dir"]
    candidates: list[Path] = []
    for root in candidate_roots(args.syn_root):
        candidates.append(root / syn_dir / REPORT_REL)
        dated = sorted(
            root.glob(f"{syn_dir}.*"),
            key=lambda p: p.stat().st_mtime if p.exists() else 0,
            reverse=True,
        )
        candidates.extend(d / REPORT_REL for d in dated)

    for rpt in candidates:
        if report_is_valid(rpt):
            return rpt

    searched = "\n  ".join(str(p) for p in candidates)
    raise SystemExit(f"no valid area report found; searched:\n  {searched}")


def load_area_report(rpt: Path) -> tuple[pd.DataFrame, float]:
    if SynopsysDesignCompilerAreaParser is not None:
        parser = SynopsysDesignCompilerAreaParser()
        db = parser.load(str(rpt))
        if db.HIERARCHY_KEY not in db.tables:
            raise SystemExit(f"hierarchy table missing in {rpt}")
        return db.tables[db.HIERARCHY_KEY], float(db.metadata["total_cell_area"])

    print(f"warning: hwexplorer unavailable ({HWEXPLORER_IMPORT_ERROR}); using local area parser")
    total_area: float | None = None
    design_name = DESIGN_NAME
    rows: list[dict[str, float | str]] = []
    in_table = False
    with rpt.open(errors="ignore") as f:
        for line in f:
            if line.startswith("Design :"):
                design_name = line.split(":", 1)[1].strip()
            elif line.startswith("Total cell area:"):
                total_area = float(line.split()[-1])
            elif line.startswith("Hierarchical area distribution"):
                in_table = True
                continue

            if not in_table:
                continue
            stripped = line.strip()
            if (
                not stripped
                or stripped.startswith("-")
                or stripped.startswith("Global")
                or stripped.startswith("Local")
                or stripped.startswith("Hierarchical")
                or stripped.startswith("Absolute")
                or stripped.startswith("Total")
            ):
                continue

            parts = stripped.split()
            if len(parts) < 6:
                continue
            try:
                area = float(parts[1])
            except ValueError:
                continue
            cell = parts[0]
            full_path = cell if cell == design_name else f"{design_name}/{cell}"
            rows.append({"full_path": full_path, "area": area})

    if total_area is None:
        raise SystemExit(f"total cell area missing in {rpt}")
    return pd.DataFrame(rows), total_area


def main():
    args = parse_args()
    rpt = resolve_report(args)
    out_name = args.syn_dir or args.run
    out_dir = HERE / re.sub(r"[^A-Za-z0-9_.-]+", "_", out_name)
    out_dir.mkdir(parents=True, exist_ok=True)

    hdf, total_area = load_area_report(rpt)

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
        if area <= 0.0 and counts[label] == 0:
            continue
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
