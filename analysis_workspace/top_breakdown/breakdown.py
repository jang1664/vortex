"""Horizontal stacked-bar area breakdown of synthesized Vortex_axi.

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
    vortex_axi_breakdown.csv         - five paper-facing area categories
    vortex_axi_breakdown_detail.csv  - auditable per-module area table
    vortex_axi_breakdown.png         - horizontal stacked bar figure
"""

from __future__ import annotations

import argparse
import math
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

SIMT_LABEL = "SIMT (excl. memory)"
MEMORY_LABEL = "Cache / LMEM / TMEM"
MXU_LABEL = "GEMM Engine"
DMA_LABEL = "DMA"
MISC_LABEL = "Misc. (incl. interconnect, mux/demux)"

SUMMARY_COLORS = {
    SIMT_LABEL: "#285980",
    MEMORY_LABEL: "#377bb1",
    MXU_LABEL: "#444444",
    DMA_LABEL: "#7a7a7a",
    MISC_LABEL: "#b5b5b5",
}

FIGURE_WIDTH_IN = 3.5
FIGURE_HEIGHT_IN = 1.5
PLOT_FONT_SIZE = 4.5
OUTPUT_DPI = 600

plt.rcParams.update({
    "font.size": PLOT_FONT_SIZE,
    "axes.titlesize": PLOT_FONT_SIZE,
    "axes.labelsize": PLOT_FONT_SIZE,
    "xtick.labelsize": PLOT_FONT_SIZE,
    "ytick.labelsize": PLOT_FONT_SIZE,
    "legend.fontsize": PLOT_FONT_SIZE,
    "figure.titlesize": PLOT_FONT_SIZE,
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
    "nt16": {
        "syn_dir": "Vortex_axi_nt16",
        "title": "NT16",
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
    ("GEMM control",                 [PREFIX_GEMM_NODE + r"/u_VX_gemm_ctrl$"]),
    ("TMEM DMA control",             [PREFIX_GEMM_NODE + r"/u_tmem_dma_ctrl$"]),
    ("job frontend",                 [PREFIX_GEMM_NODE + r"/u_job_frontend$"]),
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
    ("HBM LSU mux cuts x8",          [PREFIX_TOP + r"g_hbm_mux_\d+__u_lsu_mux_cut$"]),
    ("LSU demux",                    [PREFIX_TOP + r"u_lsu_demux$"]),
    ("AXI adapter / memory adapter / remaps",
                                     [PREFIX_TOP + r"axi_adapter$",
                                      PREFIX_TOP + r"g_mem_adapter_\d+__mem_data_adapter$",
                                      PREFIX_TOP + r"u_lsu_(ar|aw)_remap$"]),
]

SIMT_BUCKETS = {
    "ALU unit",
    "LSU unit",
    "FPU unit (FPNEW + HW exp)",
    "SFU unit",
    "TCU unit",
    "issue",
    "schedule",
    "fetch / commit / decode / DCR",
    "DMA node",
}
CACHE_BUCKETS = {
    "L1 data cache",
    "L1 instruction cache",
    "L2 cache",
    "L3 cache",
}
MEMORY_BUCKETS = CACHE_BUCKETS | {"TMEM banks (tensor memory SRAM)"}
DMA_BUCKETS = {
    "TMEM DMA engine",
    "TMEM local DMAs",
    "TMEM DMA control",
}

LOCAL_MEM_PATTERN = PREFIX_CORE + r"/mem_unit/local_mem$"


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


def exact_area(hdf: pd.DataFrame, pattern: str) -> tuple[float, int]:
    """Return the summed area and row count for an exact hierarchy pattern."""
    matches = hdf["full_path"].str.match(pattern)
    return float(hdf.loc[matches, "area"].sum()), int(matches.sum())


def summarize_for_paper(
    detail_sums: dict[str, float],
    detail_counts: dict[str, int],
    hdf: pd.DataFrame,
    total_area: float,
) -> dict[str, float]:
    """Collapse the auditable breakdown into five paper-facing categories.

    Only the `local_mem` child of `mem_unit` is classified as LMEM. The rest
    of `mem_unit` contains coalescers, adapters, arbiters, and switches and is
    therefore deliberately counted as interconnect overhead in Misc.
    """
    local_mem_area, local_mem_count = exact_area(hdf, LOCAL_MEM_PATTERN)
    missing_anchors = []
    if local_mem_count == 0:
        missing_anchors.append("LMEM (mem_unit/local_mem)")
    if detail_counts.get("GEMM unit (MXU compute)", 0) == 0:
        missing_anchors.append("MXU (gemm_node/u_VX_gemm_unit)")
    if detail_counts.get("TMEM banks (tensor memory SRAM)", 0) == 0:
        missing_anchors.append("TMEM banks")
    if sum(detail_counts.get(label, 0) for label in CACHE_BUCKETS) == 0:
        missing_anchors.append("cache (L1/L2/L3)")
    if sum(detail_counts.get(label, 0) for label in DMA_BUCKETS) == 0:
        missing_anchors.append("DMA")
    if missing_anchors:
        raise SystemExit(
            "missing required semantic anchors: " + ", ".join(missing_anchors)
        )

    mem_unit_area = detail_sums["memory unit"]
    if local_mem_area > mem_unit_area and not math.isclose(
        local_mem_area, mem_unit_area, rel_tol=1e-9, abs_tol=1e-6
    ):
        raise SystemExit(
            "local_mem area exceeds its mem_unit parent: "
            f"{local_mem_area} > {mem_unit_area}"
        )

    summary = {label: 0.0 for label in SUMMARY_COLORS}
    summary[SIMT_LABEL] = sum(
        detail_sums[label] for label in SIMT_BUCKETS
    )
    summary[MEMORY_LABEL] = local_mem_area + sum(
        detail_sums[label] for label in MEMORY_BUCKETS
    )
    summary[MXU_LABEL] = detail_sums["GEMM unit (MXU compute)"]
    summary[DMA_LABEL] = sum(detail_sums[label] for label in DMA_BUCKETS)

    assigned = sum(summary.values())
    summary[MISC_LABEL] = total_area - assigned
    if summary[MISC_LABEL] < -1e-6:
        raise SystemExit("paper categories exceed total cell area")
    summary[MISC_LABEL] = max(0.0, summary[MISC_LABEL])

    if not math.isclose(sum(summary.values()), total_area, rel_tol=1e-9, abs_tol=1e-3):
        raise SystemExit("paper categories do not sum to total cell area")

    mem_overhead = max(0.0, mem_unit_area - local_mem_area)
    print(
        "memory-unit split: "
        f"LMEM={local_mem_area / 1e6:.4f} mm², "
        f"interconnect/control={mem_overhead / 1e6:.4f} mm² -> Misc."
    )
    return summary


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

    hdf, total_area = load_area_report(rpt)

    detail_sums, detail_counts, _ = aggregate(hdf)
    summary_sums = summarize_for_paper(
        detail_sums, detail_counts, hdf, total_area
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    captured = sum(detail_sums.values())
    other = max(0.0, total_area - captured)
    detail_sums["Other / residual glue"] = other
    detail_counts["Other / residual glue"] = 0

    detail_labels = [
        label
        for label, area in detail_sums.items()
        if area > 0.0 or detail_counts[label] > 0
    ]
    detail_df = pd.DataFrame({
        "module": detail_labels,
        "num_matched": [detail_counts[label] for label in detail_labels],
        "area_um2": [detail_sums[label] for label in detail_labels],
        "area_mm2": [detail_sums[label] / 1e6 for label in detail_labels],
        "percent": [
            detail_sums[label] / total_area * 100 for label in detail_labels
        ],
    })
    detail_csv_path = out_dir / "vortex_axi_breakdown_detail.csv"
    detail_df.to_csv(detail_csv_path, index=False)

    labels = list(SUMMARY_COLORS)
    areas_um2 = [summary_sums[label] for label in labels]
    areas_mm2 = [area / 1e6 for area in areas_um2]
    pcts = [area / total_area * 100 for area in areas_um2]

    df_out = pd.DataFrame({
        "module": labels,
        "area_um2": areas_um2,
        "area_mm2": areas_mm2,
        "percent": pcts,
    })
    csv_path = out_dir / "vortex_axi_breakdown.csv"
    df_out.to_csv(csv_path, index=False)
    print(df_out.to_string(index=False, float_format=lambda v: f"{v:10.4f}"))
    print(
        f"\nTotal cell area: {total_area / 1e6:.3f} mm² "
        f"(sum of categories = {sum(areas_mm2):.3f} mm²)"
    )
    print(f"source report: {rpt}")
    print(f"wrote {csv_path}")
    print(f"wrote {detail_csv_path}")

    # ---- horizontal stacked bar ----
    fig, ax = plt.subplots(figsize=(FIGURE_WIDTH_IN, FIGURE_HEIGHT_IN))
    left = 0.0
    total_mm2 = sum(areas_mm2)
    handles = []
    for label, val_mm2, pct in zip(labels, areas_mm2, pcts):
        color = SUMMARY_COLORS[label]
        ax.barh(
            0,
            val_mm2,
            left=left,
            color=color,
            edgecolor="white",
            linewidth=0.3,
            height=0.62,
        )
        if pct >= 5.0:
            ax.text(
                left + val_mm2 / 2,
                0,
                f"{pct:.1f}%",
                ha="center",
                va="center",
                fontsize=PLOT_FONT_SIZE,
                fontweight="bold",
                color="white",
            )
        legend_label = (
            f"{label} ({pct:.1f}%)"
            if label in (DMA_LABEL, MISC_LABEL)
            else label
        )
        handles.append(
            plt.Rectangle(
                (0, 0),
                1,
                1,
                fc=color,
                label=legend_label,
                edgecolor="none",
            )
        )
        left += val_mm2

    ax.set_xlim(0.0, total_mm2)
    ax.set_ylim(-0.55, 0.55)
    ax.set_yticks([])
    ax.set_xlabel("Cumulative area (mm²)", fontweight="bold")
    ax.tick_params(axis="x", top=False, direction="inout", length=2.5)
    ax.spines[["left", "right", "top"]].set_visible(False)
    legend_handles = [handles[index] for index in (0, 2, 4, 1, 3)]
    ax.legend(
        handles=legend_handles,
        loc="upper left",
        bbox_to_anchor=(0.0, -0.78, 1.0, 0.2),
        ncol=2,
        mode="expand",
        frameon=False,
        fontsize=PLOT_FONT_SIZE,
        handlelength=0.9,
        columnspacing=1.0,
        labelspacing=0.5,
        borderaxespad=0.0,
    )

    # Keep the plotting axis nearly as wide as the fixed 3.5-inch canvas.  A
    # tight layout shrinks the bar to the longest legend entry instead.
    fig.subplots_adjust(left=0.06, right=0.985, top=0.94, bottom=0.58)
    png_path = out_dir / "vortex_axi_breakdown.png"
    fig.savefig(png_path, dpi=OUTPUT_DPI, facecolor="white")
    print(f"wrote {png_path}")
    plt.close(fig)


if __name__ == "__main__":
    main()
