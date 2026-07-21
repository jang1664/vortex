"""Horizontal stacked-bar area breakdown of synthesized Vortex_axi.

Parses the DC topographical area report with hwexplorer and emits multiple
stacked-bar views that decompose Vortex_axi cell area into meaningful
sub-blocks (gemm_node / mem_unit / caches / AXI infra / ...). The breakdown
deliberately reaches inside `vortex/cluster/socket/core` since the top-level
hierarchy is 99.6% `vortex` and not informative on its own.

Run from a Python with plotting dependencies installed (e.g. `conda activate stable`):

    python analysis_workspace/top_breakdown/breakdown.py --alias C4

FPGA aliases are read from `ci/fpga_bin_alias_map.yaml` and resolve to the
matching `run_syn_vortex_axi.py` result directory, for example alias `C4`
resolves to `build/hw/syn/synopsys/Vortex_axi_C4/syn_topo.lpp`. Alternatively,
pass that synthesis directory directly with `--syn-dir` or bypass directory
resolution entirely with `--report`.

Outputs (under analysis_workspace/top_breakdown/<run>/):
    vortex_axi_breakdown.csv          - original five paper-facing categories
    vortex_axi_breakdown.png          - original horizontal stacked bar figure
    vortex_axi_breakdown_xbar.csv     - XBAR-separated five-category version
    vortex_axi_breakdown_xbar.png     - XBAR-separated stacked bar figure
    vortex_axi_breakdown_detail.csv   - auditable per-module area table
"""

from __future__ import annotations

import argparse
import math
import os
import re
import sys
from dataclasses import dataclass
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
if str(VORTEX) not in sys.path:
    sys.path.insert(0, str(VORTEX))

from tools.latency_bench.fpga_bins import (  # noqa: E402
    alias_map_path,
    load_fpga_bin_aliases,
)

DESIGN_NAME = "Vortex_axi"
DEFAULT_ALIAS = "C4"
REPORT_NAME = "14_Vortex_axi.mapped.area.rpt"
REPORT_IN_SYN_DIR = Path("reports") / REPORT_NAME
REPORT_IN_RUN_DIR = Path("syn_topo.lpp") / REPORT_IN_SYN_DIR
# Compatibility name retained for callers that imported the old constant.
REPORT_REL = REPORT_IN_RUN_DIR

SIMT_LABEL = "SIMT (excl. memory)"
SIMT_NO_XBAR_LABEL = "SIMT (excl. SRAM / XBAR)"
MEMORY_LABEL = "Cache / LMEM / TMEM"
MXU_LABEL = "GEMM Engine"
XBAR_LABEL = "XBAR"
DMA_LABEL = "DMA"
MISC_LABEL = "Misc. (incl. interconnect, mux/demux)"
XBAR_MISC_LABEL = "Misc."


@dataclass(frozen=True)
class LegendCategory:
    label: str
    components: tuple[str, ...]
    color: str
    show_percent_in_legend: bool = False


@dataclass(frozen=True)
class LegendGroup:
    name: str
    output_suffix: str
    categories: tuple[LegendCategory, ...]
    legend_order: tuple[int, ...]


# Multiple paper-facing views of the same auditable module breakdown. An empty
# component list marks the residual category, which receives all area not
# assigned to the explicitly listed semantic components.
LEGEND_GROUPS: list[LegendGroup] = [
    LegendGroup(
        name="original",
        output_suffix="",
        categories=(
            LegendCategory(SIMT_LABEL, ("simt",), "#285980"),
            LegendCategory(MEMORY_LABEL, ("memory",), "#377bb1"),
            LegendCategory(MXU_LABEL, ("mxu",), "#444444"),
            LegendCategory(DMA_LABEL, ("dma",), "#7a7a7a", True),
            LegendCategory(MISC_LABEL, (), "#b5b5b5", True),
        ),
        legend_order=(0, 2, 4, 1, 3),
    ),
    LegendGroup(
        name="xbar",
        output_suffix="_xbar",
        categories=(
            LegendCategory(
                SIMT_NO_XBAR_LABEL, ("simt", "mxu"), "#285980"
            ),
            LegendCategory(MEMORY_LABEL, ("memory",), "#377bb1"),
            LegendCategory(XBAR_LABEL, ("xbar",), "#444444", True),
            LegendCategory(DMA_LABEL, ("dma",), "#7a7a7a", True),
            LegendCategory(XBAR_MISC_LABEL, (), "#b5b5b5", True),
        ),
        legend_order=(0, 2, 4, 1, 3),
    ),
]

# Compatibility alias for users importing the original color mapping.
SUMMARY_COLORS = {
    category.label: category.color
    for category in LEGEND_GROUPS[0].categories
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
XBAR_BUCKETS = {
    "TMEM switches",
    "socket memory arbiter",
    "HBM AXI mux x8",
    "HBM LSU mux cuts x8",
    "LSU demux",
    "AXI adapter / memory adapter / remaps",
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


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Vortex_axi top-level area breakdown."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--alias",
        default=None,
        help=(
            "FPGA config alias whose Vortex_axi_<alias>/syn_topo.lpp result "
            f"is analyzed. Default: {DEFAULT_ALIAS}."
        ),
    )
    source.add_argument(
        "--syn-dir",
        type=Path,
        default=None,
        help=(
            "Synthesis directory containing reports/"
            f"{REPORT_NAME}. Relative paths are resolved from the repository "
            "root."
        ),
    )
    source.add_argument(
        "--report",
        type=Path,
        default=None,
        help="Exact area report path; bypasses synthesis-directory resolution.",
    )
    source.add_argument(
        "--run",
        choices=RUNS.keys(),
        default=None,
        help="Legacy named synthesis run to analyze.",
    )
    parser.add_argument(
        "--syn-root",
        type=Path,
        default=None,
        help=(
            "Synthesis result root used with --alias or legacy --run. Default: "
            "SYN_RESULT_ROOT, then build/hw/syn/synopsys with legacy fallback."
        ),
    )
    parser.add_argument(
        "--alias-map",
        type=Path,
        default=None,
        help=(
            "FPGA alias map path. Default: VORTEX_FPGA_BIN_ALIAS_MAP, then "
            "ci/fpga_bin_alias_map.yaml."
        ),
    )
    args = parser.parse_args(argv)
    if all(
        selection is None
        for selection in (args.alias, args.syn_dir, args.report, args.run)
    ):
        args.alias = DEFAULT_ALIAS
    return args


def exact_area(hdf: pd.DataFrame, pattern: str) -> tuple[float, int]:
    """Return the summed area and row count for an exact hierarchy pattern."""
    matches = hdf["full_path"].str.match(pattern)
    return float(hdf.loc[matches, "area"].sum()), int(matches.sum())


def summarize_for_paper(
    detail_sums: dict[str, float],
    detail_counts: dict[str, int],
    hdf: pd.DataFrame,
    total_area: float,
    legend_group: LegendGroup | None = None,
) -> dict[str, float]:
    """Collapse the auditable breakdown into one paper-facing legend group.

    Only the `local_mem` child of `mem_unit` is classified as LMEM. The rest
    of `mem_unit` contains coalescers, adapters, arbiters, and switches and is
    therefore treated as XBAR/interconnect overhead. The original legend
    leaves that component in Misc.; the XBAR legend exposes it explicitly.
    """
    if legend_group is None:
        legend_group = LEGEND_GROUPS[0]

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

    mem_overhead = max(0.0, mem_unit_area - local_mem_area)
    components = {
        "simt": sum(detail_sums[label] for label in SIMT_BUCKETS),
        "memory": local_mem_area
        + sum(detail_sums[label] for label in MEMORY_BUCKETS),
        "mxu": detail_sums["GEMM unit (MXU compute)"],
        "dma": sum(detail_sums[label] for label in DMA_BUCKETS),
        "xbar": mem_overhead
        + sum(detail_sums[label] for label in XBAR_BUCKETS),
    }

    residual_categories = [
        category for category in legend_group.categories if not category.components
    ]
    if len(residual_categories) != 1:
        raise SystemExit(
            f"legend group {legend_group.name!r} must have one residual category"
        )

    summary = {
        category.label: sum(components[name] for name in category.components)
        for category in legend_group.categories
        if category.components
    }
    assigned = sum(summary.values())
    residual_label = residual_categories[0].label
    summary[residual_label] = total_area - assigned
    if summary[residual_label] < -1e-6:
        raise SystemExit("paper categories exceed total cell area")
    summary[residual_label] = max(0.0, summary[residual_label])
    summary = {
        category.label: summary[category.label]
        for category in legend_group.categories
    }

    if not math.isclose(sum(summary.values()), total_area, rel_tol=1e-9, abs_tol=1e-3):
        raise SystemExit("paper categories do not sum to total cell area")

    print(
        "memory-unit split: "
        f"LMEM={local_mem_area / 1e6:.4f} mm², "
        f"interconnect/control={mem_overhead / 1e6:.4f} mm² -> "
        f"{'XBAR' if any(category.label == XBAR_LABEL for category in legend_group.categories) else 'Misc.'}"
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
            VORTEX / "build/hw/syn/synopsys",
            VORTEX / "build/syn/synopsys",
        ])

    deduped: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        resolved = root if root.is_absolute() else VORTEX / root
        if resolved not in seen:
            deduped.append(resolved)
            seen.add(resolved)
    return deduped


def repo_path(path: Path) -> Path:
    """Resolve a user-supplied path relative to the repository root."""
    path = path.expanduser()
    return path if path.is_absolute() else VORTEX / path


def alias_run_dir_name(alias: str, alias_map: Path | None) -> str:
    """Validate an FPGA alias and return its synthesis result directory name."""
    selected_map = alias_map_path(alias_map)
    selected_map = repo_path(selected_map)
    try:
        aliases = load_fpga_bin_aliases(selected_map)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"unable to load FPGA alias map {selected_map}: {exc}"
        ) from exc

    if alias not in aliases:
        available = ", ".join(sorted(aliases))
        raise SystemExit(
            f"unknown FPGA alias {alias!r} in {selected_map}; available aliases: "
            f"{available or '<none>'}"
        )

    safe_tag = re.sub(r"[^A-Za-z0-9_.-]+", "_", alias).strip("._-")
    if not safe_tag:
        raise SystemExit(
            f"unable to derive a synthesis result name from alias {alias!r}"
        )
    return f"{DESIGN_NAME}_{safe_tag}"


def run_report_candidates(root: Path, run_dir_name: str) -> list[Path]:
    """Return the exact and dated-backup report candidates for one run name."""
    candidates = [root / run_dir_name / REPORT_IN_RUN_DIR]
    dated = sorted(
        root.glob(f"{run_dir_name}.*"),
        key=lambda path: path.stat().st_mtime if path.exists() else 0,
        reverse=True,
    )
    candidates.extend(path / REPORT_IN_RUN_DIR for path in dated)
    return candidates


def resolve_report(args: argparse.Namespace) -> Path:
    explicit_report = getattr(args, "report", None)
    if explicit_report is not None:
        rpt = repo_path(explicit_report)
        if not report_is_valid(rpt):
            raise SystemExit(f"area report is missing or incomplete: {rpt}")
        return rpt

    explicit_syn_dir = getattr(args, "syn_dir", None)
    if explicit_syn_dir is not None:
        syn_dir = repo_path(explicit_syn_dir)
        candidates = [
            syn_dir / REPORT_IN_SYN_DIR,
            syn_dir / REPORT_IN_RUN_DIR,
        ]
        for rpt in candidates:
            if report_is_valid(rpt):
                return rpt
        searched = "\n  ".join(str(path) for path in candidates)
        raise SystemExit(
            f"no valid area report found under synthesis directory; searched:\n  {searched}"
        )

    selected_alias = getattr(args, "alias", None)
    if selected_alias is not None:
        run_dir_name = alias_run_dir_name(
            selected_alias, getattr(args, "alias_map", None)
        )
    else:
        run = RUNS[getattr(args, "run", "current")]
        run_dir_name = run["syn_dir"]

    candidates: list[Path] = []
    for root in candidate_roots(getattr(args, "syn_root", None)):
        candidates.extend(run_report_candidates(root, run_dir_name))

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


def write_legend_group_outputs(
    legend_group: LegendGroup,
    summary_sums: dict[str, float],
    total_area: float,
    out_dir: Path,
    *,
    total_label: str = "Total cell area",
) -> None:
    """Write the CSV and stacked bar for one configured legend group."""
    labels = [category.label for category in legend_group.categories]
    areas_um2 = [summary_sums[label] for label in labels]
    areas_mm2 = [area / 1e6 for area in areas_um2]
    pcts = [area / total_area * 100 for area in areas_um2]

    df_out = pd.DataFrame({
        "module": labels,
        "area_um2": areas_um2,
        "area_mm2": areas_mm2,
        "percent": pcts,
    })
    stem = f"vortex_axi_breakdown{legend_group.output_suffix}"
    csv_path = out_dir / f"{stem}.csv"
    df_out.to_csv(csv_path, index=False)
    print(f"\nlegend group: {legend_group.name}")
    print(df_out.to_string(index=False, float_format=lambda v: f"{v:10.4f}"))
    print(
        f"{total_label}: {total_area / 1e6:.3f} mm² "
        f"(sum of categories = {sum(areas_mm2):.3f} mm²)"
    )
    print(f"wrote {csv_path}")

    fig, ax = plt.subplots(figsize=(FIGURE_WIDTH_IN, FIGURE_HEIGHT_IN))
    left = 0.0
    total_mm2 = sum(areas_mm2)
    handles = []
    for category, val_mm2, pct in zip(
        legend_group.categories, areas_mm2, pcts
    ):
        ax.barh(
            0,
            val_mm2,
            left=left,
            color=category.color,
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
            f"{category.label} ({pct:.1f}%)"
            if category.show_percent_in_legend
            else category.label
        )
        handles.append(
            plt.Rectangle(
                (0, 0),
                1,
                1,
                fc=category.color,
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
    legend_handles = [handles[index] for index in legend_group.legend_order]
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

    # Keep the plotting axis nearly as wide as the fixed 3.5-inch canvas. A
    # tight layout shrinks the bar to the longest legend entry instead.
    fig.subplots_adjust(left=0.06, right=0.985, top=0.94, bottom=0.58)
    png_path = out_dir / f"{stem}.png"
    fig.savefig(png_path, dpi=OUTPUT_DPI, facecolor="white")
    print(f"wrote {png_path}")
    plt.close(fig)


def main():
    args = parse_args()
    rpt = resolve_report(args)
    if args.alias is not None:
        out_name = args.alias
    elif args.syn_dir is not None:
        syn_dir = repo_path(args.syn_dir)
        out_name = (
            syn_dir.parent.name
            if syn_dir.name == "syn_topo.lpp"
            else syn_dir.name
        )
    elif args.report is not None:
        out_name = args.report.stem
    else:
        out_name = args.run
    out_dir = HERE / re.sub(r"[^A-Za-z0-9_.-]+", "_", out_name)

    hdf, total_area = load_area_report(rpt)

    detail_sums, detail_counts, _ = aggregate(hdf)
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

    print(f"source report: {rpt}")
    print(f"wrote {detail_csv_path}")

    for legend_group in LEGEND_GROUPS:
        summary_sums = summarize_for_paper(
            detail_sums,
            detail_counts,
            hdf,
            total_area,
            legend_group=legend_group,
        )
        write_legend_group_outputs(
            legend_group, summary_sums, total_area, out_dir
        )


if __name__ == "__main__":
    main()
