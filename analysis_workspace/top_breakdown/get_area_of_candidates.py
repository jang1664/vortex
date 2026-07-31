"""Estimate the C1--C4 top areas from reusable synthesis reports.

The exact C1, C2, and C4 top-level reports are not available yet.  This tool
uses the f16 C3 top as the common SIMT/cache/top-level backbone, adds the TCU
from its block-level report, and imports only the improve GEMM and memory-unit
roots from the older C4 top report.

Single-port compiled SRAM rows are normalized at DataFrame level before the
candidate areas are assembled. This removes register fallback implementations
and permits the same reports to be compared with either HS or HD SRAM macros.
Physical macro dimensions come from the checked-in
``lpp28_sram_macro_areas.csv`` table, so estimation does not require PDK LEFs.

Run in the stable conda environment:

    conda run -n stable python \
      analysis_workspace/top_breakdown/get_area_of_candidates.py

Example: model the previous naive accelerator with a 768 KiB LMEM and a
256 KiB ACC memory in C2 and C3:

    conda run -n stable python \
      analysis_workspace/top_breakdown/get_area_of_candidates.py \
      --sram-type HS --naive-acc \
      --c2-lmem-kib 768 --c2-acc-kib 256 \
      --c3-lmem-kib 768 --c3-acc-kib 256

The output directory contains the summary/component/audit CSV files and a
separate normalized ``original`` and ``xbar`` stacked-bar PNG/CSV pair for
each candidate and requested SRAM type. Use ``--no-plot`` when only the
numerical CSV outputs are needed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping

import pandas as pd

try:
    from analysis_workspace.top_breakdown import breakdown as area_breakdown
except ModuleNotFoundError:  # pragma: no cover - direct script invocation
    import breakdown as area_breakdown

try:
    from hwexplorer.report_parser import SynopsysDesignCompilerAreaParser
except ImportError as exc:  # pragma: no cover - depends on the Python environment
    raise SystemExit(
        "hwexplorer is required; run this script in the 'stable' conda environment"
    ) from exc


HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
TOP_ANALYSIS = VORTEX / "build/hw/syn/synopsys/top_analysis"

DEFAULT_C3_REPORT = TOP_ANALYSIS / (
    "Vortex_axi_naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16/"
    "top/reports/14_Vortex_axi.mapped.area.rpt"
)
DEFAULT_C4_REPORT = TOP_ANALYSIS / (
    "Vortex_axi_improve_th32_tcol32_hwexp_dcache/"
    "top/reports/14_Vortex_axi.mapped.area.rpt"
)
DEFAULT_TCU_REPORT = TOP_ANALYSIS / (
    "Vortex_tcu_th32_c1_rev2_subdesign_partial/blocks/blocks/"
    "VX_tcu_unit__d2e8e198f1ee/reports/"
    "14_VX_tcu_unit__d2e8e198f1ee.mapped.area.rpt"
)
DEFAULT_NAIVE_ACC_REPORT = TOP_ANALYSIS / (
    "Vortex_axi_naive_gemm_th32_tcol32_hwexp_dcache/"
    "top/reports/14_Vortex_axi.mapped.area.rpt"
)
DEFAULT_MEMORY_CSV = HERE / "lpp28_sram_macro_areas.csv"
DEFAULT_OUTPUT_DIR = HERE / "candidate_area_results"

# Reuse breakdown.py's paper-facing visual style.
FIGURE_WIDTH_IN = area_breakdown.FIGURE_WIDTH_IN
FIGURE_HEIGHT_IN = area_breakdown.FIGURE_HEIGHT_IN
PLOT_FONT_SIZE = area_breakdown.PLOT_FONT_SIZE
OUTPUT_DPI = area_breakdown.OUTPUT_DPI

CORE_PATH = (
    "Vortex_axi/vortex/g_clusters_0__cluster/g_sockets_0__socket/"
    "g_cores_0__core"
)
C3_MEM_UNIT_PATH = f"{CORE_PATH}/mem_unit"
C3_GEMM_PATH = f"{CORE_PATH}/gemm_node_naive"
C3_DMA_NODE_PATH = f"{CORE_PATH}/u_VX_dma_node"
C4_MEM_UNIT_PATH = f"{CORE_PATH}/mem_unit"
C4_GEMM_PATH = f"{CORE_PATH}/gemm_node"

CONFIG_PATHS = {
    "C1": "configs/tcu_th32_c1_rev2.sh",
    "C2": "configs/naive_gemm_tcu_th32_tcol32_hwexp_dcache_sxbar_f16.sh",
    "C3": "configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh",
    "C4": "configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16.sh",
}


@dataclass(frozen=True)
class MacroMapping:
    """Physical macro tiling used for one logical SRAM bank."""

    macro_name: str
    macros_per_bank: int


@dataclass(frozen=True)
class SramGroup:
    """A semantic collection of compiled single-port SRAM roots."""

    name: str
    path_fragments: tuple[str, ...]
    expected_roots: int
    mappings: Mapping[str, MacroMapping]


@dataclass
class AreaReport:
    """Parsed hierarchy and the report-level total cell area."""

    name: str
    path: Path
    hierarchy: pd.DataFrame
    total_area: float


@dataclass(frozen=True)
class CandidateOptions:
    """Per-candidate storage capacities and area-inclusion controls."""

    lmem_kib: int
    acc_kib: int = 0
    tmem_kib: int = 0
    include_memory: bool = True
    include_common: bool = True


@dataclass(frozen=True)
class MacroTile:
    """One native memory-compiler macro available for depth tiling."""

    depth: int
    width: int
    macro_name: str


@dataclass(frozen=True)
class MacroAreaCatalog:
    """Version-controlled physical macro areas used by the estimator."""

    source: Path
    areas_um2: Mapping[str, float]

    def area(self, macro_name: str) -> float:
        try:
            return float(self.areas_um2[macro_name])
        except KeyError as exc:
            raise ValueError(
                f"macro area is missing from {self.source}: {macro_name}"
            ) from exc


PAPER_COMPONENTS = ("simt", "memory", "mxu", "dma", "xbar", "residual")


C3_SRAM_GROUPS = (
    SramGroup(
        "LMEM_1MiB",
        ("/mem_unit/local_mem/",),
        32,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_4096x64m8", 1),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_4096x64m16", 1),
        },
    ),
    SramGroup(
        "DCACHE_data",
        ("/dcache/", "/cache_data/"),
        16,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_256x128m8", 4),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_1024x64m8", 8),
        },
    ),
    SramGroup(
        "ICACHE_data",
        ("/icache/", "/cache_data/"),
        4,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_256x128m8", 4),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_1024x64m8", 8),
        },
    ),
)

C4_SRAM_GROUPS = (
    SramGroup(
        "LMEM_512KiB",
        ("/mem_unit/local_mem/",),
        32,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_2048x64m8", 1),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_2048x64m16", 1),
        },
    ),
    SramGroup(
        "ACC",
        ("/gemm_node/u_VX_gemm_unit/gen_acc_mem_",),
        4,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_512x128m8", 8),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_1024x64m8", 16),
        },
    ),
    SramGroup(
        "TMEM",
        ("/gemm_node/u_tmem_subsystem/g_bank_",),
        8,
        {
            "HS": MacroMapping("cmos28lpp_ra1w_hs_512x128m8", 4),
            "HD": MacroMapping("cmos28lpp_ra1w_hd_1024x64m8", 8),
        },
    ),
)

NAIVE_ACC_SRAM_GROUP = SramGroup(
    "ACC",
    ("/gemm_node_naive/u_VX_gemm_unit/gen_acc_mem_",),
    4,
    {
        "HS": MacroMapping("cmos28lpp_ra1w_hs_512x128m8", 8),
        "HD": MacroMapping("cmos28lpp_ra1w_hd_1024x64m8", 16),
    },
)

C3_LMEM_GROUP = C3_SRAM_GROUPS[0]
C3_CACHE_GROUPS = C3_SRAM_GROUPS[1:]
C4_LMEM_GROUP, C4_ACC_GROUP, C4_TMEM_GROUP = C4_SRAM_GROUPS

# Native macro choices follow the macro families already used by
# VX_sp_ram_compiled. Depth tiling minimizes the sum of physical macro
# rectangles from the checked-in CSV while covering the requested logical
# depth. Macro count and unused depth are deterministic tie breakers;
# mux/decode logic is not modeled.
MACRO_FAMILIES: dict[tuple[str, str], tuple[MacroTile, ...]] = {
    ("LMEM", "HS"): (
        MacroTile(8192, 64, "cmos28lpp_ra1w_hs_8192x64m16"),
        MacroTile(4096, 64, "cmos28lpp_ra1w_hs_4096x64m8"),
        MacroTile(2048, 64, "cmos28lpp_ra1w_hs_2048x64m8"),
        MacroTile(1024, 64, "cmos28lpp_ra1w_hs_1024x64m8"),
        MacroTile(512, 64, "cmos28lpp_ra1w_hs_512x64m8"),
    ),
    ("LMEM", "HD"): (
        MacroTile(8192, 64, "cmos28lpp_ra1w_hd_8192x64m16"),
        MacroTile(4096, 64, "cmos28lpp_ra1w_hd_4096x64m16"),
        MacroTile(2048, 64, "cmos28lpp_ra1w_hd_2048x64m16"),
        MacroTile(1024, 64, "cmos28lpp_ra1w_hd_1024x64m8"),
    ),
    ("WIDE", "HS"): (
        MacroTile(4096, 128, "cmos28lpp_ra1w_hs_4096x128m8"),
        MacroTile(2048, 128, "cmos28lpp_ra1w_hs_2048x128m8"),
        MacroTile(1024, 128, "cmos28lpp_ra1w_hs_1024x128m8"),
        MacroTile(512, 128, "cmos28lpp_ra1w_hs_512x128m8"),
        MacroTile(256, 128, "cmos28lpp_ra1w_hs_256x128m8"),
    ),
    ("WIDE", "HD"): (
        MacroTile(8192, 64, "cmos28lpp_ra1w_hd_8192x64m16"),
        MacroTile(4096, 64, "cmos28lpp_ra1w_hd_4096x64m16"),
        MacroTile(2048, 64, "cmos28lpp_ra1w_hd_2048x64m16"),
        MacroTile(1024, 64, "cmos28lpp_ra1w_hd_1024x64m8"),
    ),
}

def resolve_path(path: Path) -> Path:
    """Resolve command-line paths relative to the repository root."""
    path = path.expanduser()
    return path if path.is_absolute() else VORTEX / path


def load_area_report(name: str, path: Path) -> AreaReport:
    """Load a Design Compiler area report with hwexplorer."""
    path = resolve_path(path)
    if not path.is_file():
        raise FileNotFoundError(f"{name} area report does not exist: {path}")

    parser = SynopsysDesignCompilerAreaParser()
    database = parser.load(str(path))
    if database.HIERARCHY_KEY not in database.tables:
        raise ValueError(f"{name} hierarchy table is missing from {path}")
    if "total_cell_area" not in database.metadata:
        raise ValueError(f"{name} total cell area is missing from {path}")

    hierarchy = database.tables[database.HIERARCHY_KEY].copy(deep=True)
    required_columns = {
        "full_path",
        "parent_path",
        "module_name",
        "area",
        "percent",
        "comb_area",
        "non_comb_area",
        "blackbox_area",
    }
    missing = sorted(required_columns - set(hierarchy.columns))
    if missing:
        raise ValueError(f"{name} hierarchy is missing columns: {', '.join(missing)}")

    return AreaReport(name, path, hierarchy, float(database.metadata["total_cell_area"]))


def required_macro_names() -> set[str]:
    """Return every macro name reachable by fixed or configurable mappings."""
    names = {
        tile.macro_name
        for family in MACRO_FAMILIES.values()
        for tile in family
    }
    for group in (*C3_SRAM_GROUPS, *C4_SRAM_GROUPS, NAIVE_ACC_SRAM_GROUP):
        names.update(mapping.macro_name for mapping in group.mappings.values())
    return names


def load_macro_area_catalog(path: Path = DEFAULT_MEMORY_CSV) -> MacroAreaCatalog:
    """Load and validate the checked-in SRAM physical-dimension table."""
    path = resolve_path(path)
    if not path.is_file():
        raise FileNotFoundError(f"SRAM macro area CSV does not exist: {path}")
    table = pd.read_csv(path)
    required_columns = {
        "macro_name",
        "sram_type",
        "depth",
        "data_width",
        "width_um",
        "height_um",
        "area_um2",
    }
    missing_columns = sorted(required_columns - set(table.columns))
    if missing_columns:
        raise ValueError(
            f"SRAM macro area CSV is missing columns: {', '.join(missing_columns)}"
        )
    if table["macro_name"].isna().any() or table["macro_name"].duplicated().any():
        raise ValueError("SRAM macro area CSV has empty or duplicate macro names")

    for column in ("depth", "data_width", "width_um", "height_um", "area_um2"):
        table[column] = pd.to_numeric(table[column], errors="raise")
        if (table[column] <= 0).any():
            raise ValueError(f"SRAM macro area CSV has non-positive {column}")
    calculated_area = table["width_um"] * table["height_um"]
    if ((calculated_area - table["area_um2"]).abs() > 1e-6).any():
        raise ValueError("SRAM macro area CSV has inconsistent rectangle areas")

    missing_macros = sorted(required_macro_names() - set(table["macro_name"]))
    if missing_macros:
        raise ValueError(
            "SRAM macro area CSV is missing required macros: "
            + ", ".join(missing_macros)
        )
    indexed = table.set_index("macro_name")
    for (_, expected_type), family in MACRO_FAMILIES.items():
        for tile in family:
            row = indexed.loc[tile.macro_name]
            actual = (
                str(row["sram_type"]).upper(),
                int(row["depth"]),
                int(row["data_width"]),
            )
            expected = (expected_type, tile.depth, tile.width)
            if actual != expected:
                raise ValueError(
                    f"SRAM macro metadata mismatch for {tile.macro_name}: "
                    f"expected {expected}, got {actual}"
                )
    return MacroAreaCatalog(
        source=path,
        areas_um2=dict(zip(table["macro_name"], table["area_um2"])),
    )


def default_candidate_options(naive_acc: bool = False) -> dict[str, CandidateOptions]:
    """Return the current C1--C4 capacities, optionally restoring naive ACC."""
    naive_acc_kib = 256 if naive_acc else 0
    return {
        "C1": CandidateOptions(lmem_kib=1024),
        "C2": CandidateOptions(lmem_kib=1024, acc_kib=naive_acc_kib),
        "C3": CandidateOptions(lmem_kib=1024, acc_kib=naive_acc_kib),
        "C4": CandidateOptions(lmem_kib=512, acc_kib=256, tmem_kib=256),
    }


def validate_candidate_options(
    options: Mapping[str, CandidateOptions], naive_acc: bool
) -> dict[str, CandidateOptions]:
    """Validate candidate names, capacities, and architecture compatibility."""
    missing = sorted(set(CONFIG_PATHS) - set(options))
    extra = sorted(set(options) - set(CONFIG_PATHS))
    if missing or extra:
        raise ValueError(
            f"candidate option keys mismatch; missing={missing or '<none>'}, "
            f"extra={extra or '<none>'}"
        )

    validated = dict(options)
    for candidate, option in validated.items():
        for field_name in ("lmem_kib", "acc_kib", "tmem_kib"):
            value = getattr(option, field_name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(
                    f"{candidate} {field_name} must be a non-negative integer, got {value!r}"
                )

    if validated["C1"].acc_kib or validated["C1"].tmem_kib:
        raise ValueError("C1 has no ACC/TMEM architecture; their capacities must be zero")
    if validated["C2"].tmem_kib or validated["C3"].tmem_kib:
        raise ValueError("C2/C3 naive designs have no TMEM; tmem_kib must be zero")
    if not naive_acc and (validated["C2"].acc_kib or validated["C3"].acc_kib):
        raise ValueError("C2/C3 ACC capacity requires naive_acc=True or --naive-acc")
    return validated


def capacity_to_depth(capacity_kib: int, banks: int, logical_width: int) -> int:
    """Convert a total KiB capacity to the depth of each logical bank."""
    total_bits = capacity_kib * 1024 * 8
    bits_per_row = banks * logical_width
    if total_bits % bits_per_row:
        raise ValueError(
            f"{capacity_kib} KiB cannot be divided into {banks} banks of "
            f"{logical_width}-bit rows"
        )
    return total_bits // bits_per_row


def choose_depth_tiles(
    required_depth: int,
    family: tuple[MacroTile, ...],
    macro_catalog: MacroAreaCatalog,
) -> list[MacroTile]:
    """Choose the minimum-area native-macro cover for one bank depth.

    The search permits physical over-provisioning when it saves macro area.
    Among equal-area covers, it prefers fewer macros and then less unused
    depth.  Logic needed to select and mux multiple depth tiles is outside the
    current area model.
    """
    if required_depth == 0:
        return []
    if not family:
        raise ValueError("cannot tile SRAM depth with an empty macro family")

    # An optimal cover never needs to exceed required_depth + max_depth - 1:
    # beyond that bound, removing any one tile still covers the requirement
    # and strictly reduces area.
    max_depth = max(tile.depth for tile in family)
    search_limit = required_depth + max_depth - 1
    tile_areas = {
        tile.macro_name: macro_catalog.area(tile.macro_name)
        for tile in family
    }

    # depth -> (area, macro_count, tuple of tile indices)
    best: dict[int, tuple[float, int, tuple[int, ...]]] = {0: (0.0, 0, ())}
    for depth in range(search_limit + 1):
        state = best.get(depth)
        if state is None:
            continue
        area, count, indices = state
        for tile_index, tile in enumerate(family):
            next_depth = depth + tile.depth
            if next_depth > search_limit:
                continue
            candidate = (
                area + tile_areas[tile.macro_name],
                count + 1,
                indices + (tile_index,),
            )
            incumbent = best.get(next_depth)
            if incumbent is None or candidate[:2] < incumbent[:2]:
                best[next_depth] = candidate

    covers = [
        (area, count, depth - required_depth, indices)
        for depth, (area, count, indices) in best.items()
        if depth >= required_depth
    ]
    if not covers:
        raise ValueError(f"cannot cover SRAM depth {required_depth}")
    _, _, _, selected_indices = min(covers)
    selected = [family[index] for index in selected_indices]
    return sorted(selected, key=lambda tile: tile.depth, reverse=True)


def estimate_memory_macro(
    candidate: str,
    memory_name: str,
    capacity_kib: int,
    banks: int,
    logical_width: int,
    sram_type: str,
    macro_catalog: MacroAreaCatalog,
    included: bool,
) -> dict[str, object]:
    """Estimate a configurable LMEM/ACC/TMEM using catalog rectangles."""
    family_name = "LMEM" if memory_name == "LMEM" else "WIDE"
    family = MACRO_FAMILIES[(family_name, sram_type)]
    logical_depth = capacity_to_depth(capacity_kib, banks, logical_width)
    depth_tiles = choose_depth_tiles(logical_depth, family, macro_catalog)
    physical_width = family[0].width
    if logical_width % physical_width:
        raise ValueError(
            f"{candidate} {memory_name}: logical width {logical_width} is not "
            f"divisible by physical width {physical_width}"
        )
    width_tiles = logical_width // physical_width

    tile_counts: dict[str, int] = {}
    tile_depths: dict[str, int] = {}
    area_per_bank = 0.0
    for tile in depth_tiles:
        tile_counts[tile.macro_name] = tile_counts.get(tile.macro_name, 0) + width_tiles
        tile_depths[tile.macro_name] = tile.depth
        area_per_bank += macro_catalog.area(tile.macro_name) * width_tiles

    total_macro_area = area_per_bank * banks
    total_macros = sum(tile_counts.values()) * banks
    physical_depth = sum(tile.depth for tile in depth_tiles)
    tile_plan = " + ".join(
        f"{count}x{name}" for name, count in tile_counts.items()
    ) or "none"
    return {
        "candidate": candidate,
        "sram_type": sram_type,
        "group": memory_name,
        "capacity_kib": capacity_kib,
        "included": included,
        "logical_banks": banks,
        "logical_width": logical_width,
        "logical_depth": logical_depth,
        "physical_depth": physical_depth,
        "unused_depth_per_bank": max(0, physical_depth - logical_depth),
        "width_tiles": width_tiles,
        "tile_plan_per_bank": tile_plan,
        "total_macros": total_macros,
        "macro_area_um2": pd.NA,
        "total_macro_area_um2": total_macro_area,
        "included_area_um2": total_macro_area if included else 0.0,
        "source": "SRAM_macro_area_CSV",
        "source_report": str(macro_catalog.source),
    }


def _select_sram_roots(hierarchy: pd.DataFrame, group: SramGroup) -> pd.DataFrame:
    """Select only SP compiled wrapper roots belonging to one memory group."""
    mask = hierarchy["full_path"].str.endswith(
        "/g_compiled_u_compiled", na=False
    ) & hierarchy["module_name"].str.startswith("VX_sp_ram_compiled", na=False)
    for fragment in group.path_fragments:
        mask &= hierarchy["full_path"].str.contains(fragment, regex=False, na=False)
    roots = hierarchy.loc[mask]
    if len(roots) != group.expected_roots:
        raise ValueError(
            f"{group.name}: expected {group.expected_roots} SP SRAM roots, "
            f"found {len(roots)}"
        )
    return roots


def replace_sram_with_area(
    report: AreaReport,
    group: SramGroup,
    sram_type: str,
    macro_area_per_root: float,
    macro_name: str,
    macros_per_bank: int,
) -> dict[str, object]:
    """Replace one SRAM group with a supplied per-root physical macro area.

    Existing black-box implementations retain their local wrapper glue.  A
    register fallback is replaced in full because its combinational and
    sequential local areas implement the memory itself.  Descendants of a
    replaced fallback are removed so the normalized hierarchy remains
    semantically consistent with a leaf macro wrapper.
    """
    roots = _select_sram_roots(report.hierarchy, group)
    root_records = list(roots.to_dict("index").items())
    root_paths = [str(record["full_path"]) for _, record in root_records]

    # Semantic SRAM groups must never overlap or contain one another.
    for index, path in enumerate(root_paths):
        for other in root_paths[index + 1 :]:
            if path.startswith(other + "/") or other.startswith(path + "/"):
                raise ValueError(f"{group.name}: nested replacement roots: {path}, {other}")

    total_old_area = 0.0
    total_old_blackbox_area = 0.0
    total_wrapper_area = 0.0
    total_new_area = 0.0
    total_delta = 0.0
    fallback_roots = 0
    descendants_to_drop: set[object] = set()

    for row_index, row in root_records:
        root_path = str(row["full_path"])
        old_area = float(row["area"])
        old_blackbox_area = float(row["blackbox_area"])
        if old_blackbox_area > 0.0:
            wrapper_area = old_area - old_blackbox_area
            if wrapper_area < -1e-6:
                raise ValueError(
                    f"{group.name}: black-box area exceeds root area at {root_path}"
                )
            wrapper_area = max(0.0, wrapper_area)
            new_area = wrapper_area + macro_area_per_root
        else:
            wrapper_area = 0.0
            new_area = macro_area_per_root
            fallback_roots += 1
            descendant_mask = report.hierarchy["full_path"].str.startswith(
                root_path + "/", na=False
            )
            descendants_to_drop.update(report.hierarchy.index[descendant_mask])
            report.hierarchy.at[row_index, "comb_area"] = 0.0
            report.hierarchy.at[row_index, "non_comb_area"] = 0.0

        delta = new_area - old_area
        ancestor_mask = report.hierarchy["full_path"].map(
            lambda candidate: root_path.startswith(str(candidate) + "/")
        )
        report.hierarchy.loc[ancestor_mask, "area"] = (
            report.hierarchy.loc[ancestor_mask, "area"].astype(float) + delta
        )
        report.hierarchy.at[row_index, "area"] = new_area
        report.hierarchy.at[row_index, "blackbox_area"] = macro_area_per_root

        total_old_area += old_area
        total_old_blackbox_area += old_blackbox_area
        total_wrapper_area += wrapper_area
        total_new_area += new_area
        total_delta += delta

    if descendants_to_drop:
        report.hierarchy.drop(index=list(descendants_to_drop), inplace=True)

    report.total_area += total_delta
    report.hierarchy["percent"] = (
        report.hierarchy["area"].astype(float) / report.total_area * 100.0
    )

    return {
        "source": report.name,
        "source_report": str(report.path),
        "sram_type": sram_type,
        "group": group.name,
        "logical_banks": group.expected_roots,
        "fallback_roots": fallback_roots,
        "macro_name": macro_name,
        "macros_per_bank": macros_per_bank,
        "total_macros": macros_per_bank * group.expected_roots,
        "macro_area_um2": macro_area_per_root / macros_per_bank
        if macros_per_bank
        else 0.0,
        "total_macro_area_um2": macro_area_per_root * group.expected_roots,
        "old_root_area_um2": total_old_area,
        "old_blackbox_area_um2": total_old_blackbox_area,
        "preserved_wrapper_area_um2": total_wrapper_area,
        "new_root_area_um2": total_new_area,
        "delta_area_um2": total_delta,
    }


def replace_sram_macro(
    report: AreaReport,
    group: SramGroup,
    sram_type: str,
    macro_catalog: MacroAreaCatalog,
) -> dict[str, object]:
    """Replace one SRAM group with its fixed registered HS/HD mapping."""
    sram_type = sram_type.upper()
    if sram_type not in group.mappings:
        raise ValueError(f"unsupported SRAM type {sram_type!r} for {group.name}")
    mapping = group.mappings[sram_type]
    macro_area = macro_catalog.area(mapping.macro_name)
    audit = replace_sram_with_area(
        report,
        group,
        sram_type,
        macro_area * mapping.macros_per_bank,
        mapping.macro_name,
        mapping.macros_per_bank,
    )
    audit["macro_area_source"] = str(macro_catalog.source)
    return audit


def strip_sram_group(report: AreaReport, group: SramGroup, sram_type: str) -> None:
    """Remove SRAM macro/storage area while retaining real wrapper glue."""
    replace_sram_with_area(report, group, sram_type, 0.0, "excluded", 0)


def correct_sram_groups(
    source: AreaReport,
    groups: Iterable[SramGroup],
    sram_type: str,
    macro_catalog: MacroAreaCatalog,
) -> tuple[AreaReport, list[dict[str, object]]]:
    """Return a corrected copy of a report and its SRAM replacement audit."""
    corrected = AreaReport(
        source.name,
        source.path,
        source.hierarchy.copy(deep=True),
        source.total_area,
    )
    audit = [
        replace_sram_macro(corrected, group, sram_type, macro_catalog)
        for group in groups
    ]
    return corrected, audit


def exact_root_area(report: AreaReport, full_path: str) -> float:
    """Return the inclusive area of exactly one semantic hierarchy root."""
    matches = report.hierarchy.loc[report.hierarchy["full_path"].eq(full_path)]
    if len(matches) != 1:
        raise ValueError(
            f"{report.name}: expected one hierarchy row for {full_path}, "
            f"found {len(matches)}"
        )
    return float(matches.iloc[0]["area"])


def semantic_area_breakdown(
    report: AreaReport,
    full_path: str | None = None,
) -> dict[str, float]:
    """Classify a report or hierarchy root using breakdown.py semantics."""
    hierarchy = report.hierarchy.copy(deep=True)
    if full_path is None:
        total_area = report.total_area
    else:
        hierarchy = hierarchy.loc[
            hierarchy["full_path"].map(
                lambda path: path == full_path or path.startswith(full_path + "/")
            )
        ].copy()
        total_area = exact_root_area(report, full_path)

    # breakdown.py targets the improve hierarchy name. Naive GEMM uses the
    # same semantic child names under gemm_node_naive, so normalize only the
    # path spelling before applying its regular expressions.
    hierarchy["full_path"] = hierarchy["full_path"].str.replace(
        "/gemm_node_naive", "/gemm_node", regex=False
    )
    detail_sums, _, _ = area_breakdown.aggregate(hierarchy)
    local_mem_area, _ = area_breakdown.exact_area(
        hierarchy, area_breakdown.LOCAL_MEM_PATTERN
    )
    mem_unit_area = detail_sums["memory unit"]
    if local_mem_area > mem_unit_area + 1e-6:
        raise ValueError(
            f"{report.name}: local-memory area exceeds memory-unit area"
        )

    semantic = {
        "simt": sum(
            detail_sums[label] for label in area_breakdown.SIMT_BUCKETS
        ),
        "memory": local_mem_area
        + sum(
            detail_sums[label] for label in area_breakdown.MEMORY_BUCKETS
        ),
        "mxu": detail_sums["GEMM unit (MXU compute)"],
        "dma": sum(
            detail_sums[label] for label in area_breakdown.DMA_BUCKETS
        ),
        "xbar": max(0.0, mem_unit_area - local_mem_area)
        + sum(
            detail_sums[label] for label in area_breakdown.XBAR_BUCKETS
        ),
    }
    semantic["residual"] = total_area - sum(semantic.values())
    if semantic["residual"] < -1e-3:
        raise ValueError(
            f"{report.name}: semantic categories exceed root area by "
            f"{-semantic['residual']} um^2"
        )
    semantic["residual"] = max(0.0, semantic["residual"])
    return semantic


def subtract_semantic_areas(
    minuend: Mapping[str, float],
    *subtrahends: Mapping[str, float],
) -> dict[str, float]:
    """Subtract semantic component maps with numerical-tolerance checks."""
    result = {
        component: float(minuend.get(component, 0.0))
        - sum(float(areas.get(component, 0.0)) for areas in subtrahends)
        for component in PAPER_COMPONENTS
    }
    for component, area in result.items():
        if area < -1e-3:
            raise ValueError(
                f"semantic component {component} became negative: {area}"
            )
        result[component] = max(0.0, area)
    return result


def _component_row(
    candidate: str,
    sram_type: str,
    component: str,
    area: float,
    source: AreaReport,
    semantic_areas: Mapping[str, float],
) -> dict[str, object]:
    row = {
        "candidate": candidate,
        "config": CONFIG_PATHS[candidate],
        "sram_type": sram_type,
        "component": component,
        "area_um2": area,
        "area_mm2": area / 1e6,
        "source": source.name,
        "source_report": str(source.path),
    }
    row.update(
        {
            f"{name}_area_um2": float(semantic_areas.get(name, 0.0))
            for name in PAPER_COMPONENTS
        }
    )
    if abs(sum(row[f"{name}_area_um2"] for name in PAPER_COMPONENTS) - area) > 1e-3:
        raise ValueError(f"{candidate} {component}: semantic areas do not sum to area")
    return row


def _memory_component_row(
    candidate: str,
    sram_type: str,
    estimate: Mapping[str, object],
) -> dict[str, object]:
    area = float(estimate["included_area_um2"])
    row = {
        "candidate": candidate,
        "config": CONFIG_PATHS[candidate],
        "sram_type": sram_type,
        "component": (
            f"{candidate} {estimate['group']} SRAM "
            f"({estimate['capacity_kib']} KiB)"
        ),
        "area_um2": area,
        "area_mm2": area / 1e6,
        "source": estimate["source"],
        "source_report": estimate["source_report"],
    }
    row.update(
        {
            f"{name}_area_um2": area
            if name == ("mxu" if estimate["group"] == "ACC" else "memory")
            else 0.0
            for name in PAPER_COMPONENTS
        }
    )
    return row


def assemble_candidates(
    c3_logic: AreaReport,
    c4_logic: AreaReport,
    tcu: AreaReport,
    sram_type: str,
    candidate_options: Mapping[str, CandidateOptions],
    naive_acc: bool,
    macro_catalog: MacroAreaCatalog,
    naive_acc_logic: AreaReport | None = None,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Assemble additive C1--C4 components without hierarchy double counting."""
    c3_mem_logic = exact_root_area(c3_logic, C3_MEM_UNIT_PATH)
    c3_gemm = exact_root_area(c3_logic, C3_GEMM_PATH)
    c3_dma_node = exact_root_area(c3_logic, C3_DMA_NODE_PATH)
    c4_mem_logic = exact_root_area(c4_logic, C4_MEM_UNIT_PATH)
    c4_gemm_logic = exact_root_area(c4_logic, C4_GEMM_PATH)
    common_backbone = (
        c3_logic.total_area - c3_mem_logic - c3_gemm - c3_dma_node
    )
    if common_backbone <= 0.0:
        raise ValueError(f"C3 common backbone is not positive: {common_backbone}")

    c3_mem_semantic = semantic_area_breakdown(c3_logic, C3_MEM_UNIT_PATH)
    c3_gemm_semantic = semantic_area_breakdown(c3_logic, C3_GEMM_PATH)
    c3_dma_semantic = semantic_area_breakdown(c3_logic, C3_DMA_NODE_PATH)
    common_semantic = subtract_semantic_areas(
        semantic_area_breakdown(c3_logic),
        c3_mem_semantic,
        c3_gemm_semantic,
        c3_dma_semantic,
    )
    c4_mem_semantic = semantic_area_breakdown(c4_logic, C4_MEM_UNIT_PATH)
    c4_gemm_semantic = semantic_area_breakdown(c4_logic, C4_GEMM_PATH)
    tcu_semantic = {"simt": tcu.total_area}

    if naive_acc:
        if naive_acc_logic is None:
            raise ValueError("naive ACC logic report is required when naive_acc=True")
        naive_gemm_logic = exact_root_area(naive_acc_logic, C3_GEMM_PATH)
        naive_source = naive_acc_logic
        naive_label = "Previous naive GEMM logic"
        naive_gemm_semantic = semantic_area_breakdown(
            naive_acc_logic, C3_GEMM_PATH
        )
    else:
        naive_gemm_logic = c3_gemm
        naive_source = c3_logic
        naive_label = "Current naive GEMM logic"
        naive_gemm_semantic = c3_gemm_semantic

    architecture_components = {
        "C1": (
            ("C3 memory-unit logic", c3_mem_logic, c3_logic, c3_mem_semantic),
            ("TCU unit", tcu.total_area, tcu, tcu_semantic),
        ),
        "C2": (
            ("C3 memory-unit logic", c3_mem_logic, c3_logic, c3_mem_semantic),
            (
                naive_label,
                naive_gemm_logic,
                naive_source,
                naive_gemm_semantic,
            ),
            ("C3 naive DMA node", c3_dma_node, c3_logic, c3_dma_semantic),
            ("TCU unit", tcu.total_area, tcu, tcu_semantic),
        ),
        "C3": (
            ("C3 memory-unit logic", c3_mem_logic, c3_logic, c3_mem_semantic),
            (
                naive_label,
                naive_gemm_logic,
                naive_source,
                naive_gemm_semantic,
            ),
            ("C3 naive DMA node", c3_dma_node, c3_logic, c3_dma_semantic),
        ),
        "C4": (
            ("C4 memory-unit logic", c4_mem_logic, c4_logic, c4_mem_semantic),
            (
                "C4 improve GEMM logic",
                c4_gemm_logic,
                c4_logic,
                c4_gemm_semantic,
            ),
        ),
    }

    component_rows: list[dict[str, object]] = []
    memory_audit: list[dict[str, object]] = []
    for candidate, components in architecture_components.items():
        option = candidate_options[candidate]
        if option.include_common:
            component_rows.append(
                _component_row(
                    candidate,
                    sram_type,
                    "C3 f16 common backbone",
                    common_backbone,
                    c3_logic,
                    common_semantic,
                )
            )
        for component, area, source, semantic_areas in components:
            component_rows.append(
                _component_row(
                    candidate,
                    sram_type,
                    component,
                    area,
                    source,
                    semantic_areas,
                )
            )

        memory_specs = [("LMEM", option.lmem_kib, 32, 64)]
        if candidate in {"C2", "C3"} and naive_acc:
            memory_specs.append(("ACC", option.acc_kib, 4, 1024))
        if candidate == "C4":
            memory_specs.extend(
                [
                    ("ACC", option.acc_kib, 4, 1024),
                    ("TMEM", option.tmem_kib, 8, 512),
                ]
            )
        for memory_name, capacity_kib, banks, width in memory_specs:
            estimate = estimate_memory_macro(
                candidate,
                memory_name,
                capacity_kib,
                banks,
                width,
                sram_type,
                macro_catalog,
                option.include_memory,
            )
            memory_audit.append(estimate)
            if option.include_memory and capacity_kib:
                component_rows.append(
                    _memory_component_row(candidate, sram_type, estimate)
                )

    components = pd.DataFrame(component_rows)

    summary = (
        components.groupby(["candidate", "config", "sram_type"], as_index=False)[
            "area_um2"
        ]
        .sum()
        .rename(columns={"area_um2": "total_area_um2"})
    )
    summary["total_area_mm2"] = summary["total_area_um2"] / 1e6
    option_rows = pd.DataFrame(
        [
            {
                "candidate": candidate,
                "lmem_kib": option.lmem_kib,
                "acc_kib": option.acc_kib,
                "tmem_kib": option.tmem_kib,
                "total_local_memory_kib": (
                    option.lmem_kib + option.acc_kib + option.tmem_kib
                ),
                "include_memory": option.include_memory,
                "include_common": option.include_common,
                "naive_acc": naive_acc if candidate in {"C2", "C3"} else False,
            }
            for candidate, option in candidate_options.items()
        ]
    )
    summary = summary.merge(option_rows, on="candidate", how="left", validate="one_to_one")
    c1_area = float(summary.loc[summary["candidate"].eq("C1"), "total_area_um2"].iloc[0])
    summary["delta_vs_c1_um2"] = summary["total_area_um2"] - c1_area
    summary["overhead_vs_c1_pct"] = summary["delta_vs_c1_um2"] / c1_area * 100.0
    summary["estimate_status"] = "provisional"
    order = {candidate: index for index, candidate in enumerate(CONFIG_PATHS)}
    summary["_order"] = summary["candidate"].map(order)
    summary.sort_values("_order", inplace=True)
    summary.drop(columns="_order", inplace=True)
    summary.reset_index(drop=True, inplace=True)
    return summary, components, pd.DataFrame(memory_audit)


def get_top_areas(
    c3_report: Path = DEFAULT_C3_REPORT,
    c4_report: Path = DEFAULT_C4_REPORT,
    tcu_report: Path = DEFAULT_TCU_REPORT,
    memory_csv: Path = DEFAULT_MEMORY_CSV,
    sram_types: Iterable[str] = ("HS", "HD"),
    candidate_options: Mapping[str, CandidateOptions] | None = None,
    naive_acc: bool = False,
    naive_acc_report: Path = DEFAULT_NAIVE_ACC_REPORT,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Calculate candidate summaries, components, and SRAM replacement audit."""
    if candidate_options is None:
        candidate_options = default_candidate_options(naive_acc)
    candidate_options = validate_candidate_options(candidate_options, naive_acc)
    macro_catalog = load_macro_area_catalog(memory_csv)
    raw_c3 = load_area_report("C3_top", c3_report)
    raw_c4 = load_area_report("C4_old_top", c4_report)
    tcu = load_area_report("TCU_submodule", tcu_report)
    raw_naive_acc = (
        load_area_report("Naive_ACC_old_top", naive_acc_report)
        if naive_acc
        else None
    )

    summaries = []
    components = []
    audits = []
    for requested_type in sram_types:
        sram_type = requested_type.upper()
        if sram_type not in {"HS", "HD"}:
            raise ValueError(f"unsupported SRAM type: {requested_type}")
        c3_logic, cache_audit = correct_sram_groups(
            raw_c3, C3_CACHE_GROUPS, sram_type, macro_catalog
        )
        strip_sram_group(c3_logic, C3_LMEM_GROUP, sram_type)

        c4_logic = AreaReport(
            raw_c4.name,
            raw_c4.path,
            raw_c4.hierarchy.copy(deep=True),
            raw_c4.total_area,
        )
        for group in (C4_LMEM_GROUP, C4_ACC_GROUP, C4_TMEM_GROUP):
            strip_sram_group(c4_logic, group, sram_type)

        naive_acc_logic = None
        if raw_naive_acc is not None:
            naive_acc_logic = AreaReport(
                raw_naive_acc.name,
                raw_naive_acc.path,
                raw_naive_acc.hierarchy.copy(deep=True),
                raw_naive_acc.total_area,
            )
            strip_sram_group(naive_acc_logic, NAIVE_ACC_SRAM_GROUP, sram_type)

        summary, component, memory_audit = assemble_candidates(
            c3_logic,
            c4_logic,
            tcu,
            sram_type,
            candidate_options,
            naive_acc,
            macro_catalog,
            naive_acc_logic,
        )
        summaries.append(summary)
        components.append(component)
        for row in cache_audit:
            row["candidate"] = "COMMON"
            row["capacity_kib"] = pd.NA
            row["included"] = True
        audits.extend(cache_audit)
        audits.extend(memory_audit.to_dict("records"))

    return (
        pd.concat(summaries, ignore_index=True),
        pd.concat(components, ignore_index=True),
        pd.DataFrame(audits),
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Estimate C1--C4 area using reusable top and block reports."
    )
    parser.add_argument("--c3-report", type=Path, default=DEFAULT_C3_REPORT)
    parser.add_argument("--c4-report", type=Path, default=DEFAULT_C4_REPORT)
    parser.add_argument("--tcu-report", type=Path, default=DEFAULT_TCU_REPORT)
    parser.add_argument(
        "--naive-acc-report", type=Path, default=DEFAULT_NAIVE_ACC_REPORT
    )
    parser.add_argument(
        "--memory-csv",
        type=Path,
        default=DEFAULT_MEMORY_CSV,
        help="Version-controlled SRAM macro dimensions/area CSV.",
    )
    parser.add_argument(
        "--naive-acc",
        action=argparse.BooleanOptionalAction,
        default=False,
        help=(
            "Use the previous naive GEMM logic with ACC memory for C2/C3. "
            "Its default ACC capacity is 256 KiB."
        ),
    )
    parser.add_argument(
        "--sram-type",
        choices=("HS", "HD", "both"),
        default="both",
        help="SRAM implementation to estimate (default: both).",
    )
    for candidate in CONFIG_PATHS:
        prefix = candidate.lower()
        group = parser.add_argument_group(f"{candidate} area options")
        group.add_argument(f"--{prefix}-lmem-kib", type=int, default=None)
        group.add_argument(f"--{prefix}-acc-kib", type=int, default=None)
        group.add_argument(f"--{prefix}-tmem-kib", type=int, default=None)
        group.add_argument(
            f"--{prefix}-include-memory",
            action=argparse.BooleanOptionalAction,
            default=None,
            help="Include LMEM/ACC/TMEM macro area (default: enabled).",
        )
        group.add_argument(
            f"--{prefix}-include-common",
            action=argparse.BooleanOptionalAction,
            default=None,
            help=(
                "Include the shared C3 f16 SIMT/cache/top backbone "
                "(default: enabled)."
            ),
        )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--plot",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Write separate normalized breakdown.py original/xbar plots for "
            "each C1--C4 candidate and SRAM type."
        ),
    )
    return parser.parse_args(argv)


def candidate_options_from_args(args: argparse.Namespace) -> dict[str, CandidateOptions]:
    """Apply per-candidate CLI overrides to the selected architecture defaults."""
    defaults = default_candidate_options(args.naive_acc)
    options = {}
    for candidate, default in defaults.items():
        prefix = candidate.lower()
        values = {}
        for field_name in (
            "lmem_kib",
            "acc_kib",
            "tmem_kib",
            "include_memory",
            "include_common",
        ):
            override = getattr(args, f"{prefix}_{field_name}")
            values[field_name] = (
                getattr(default, field_name) if override is None else override
            )
        options[candidate] = CandidateOptions(**values)
    return validate_candidate_options(options, args.naive_acc)


def _print_summary(summary: pd.DataFrame) -> None:
    display = summary[
        [
            "sram_type",
            "candidate",
            "lmem_kib",
            "acc_kib",
            "tmem_kib",
            "include_memory",
            "include_common",
            "total_area_mm2",
            "overhead_vs_c1_pct",
        ]
    ].copy()
    display["total_area_mm2"] = display["total_area_mm2"].map(lambda value: f"{value:.6f}")
    display["overhead_vs_c1_pct"] = display["overhead_vs_c1_pct"].map(
        lambda value: f"{value:.3f}"
    )
    print(display.to_string(index=False))


def build_plot_breakdown(
    summary: pd.DataFrame,
    components: pd.DataFrame,
    sram_type: str,
    legend_group: area_breakdown.LegendGroup,
) -> pd.DataFrame:
    """Project candidate semantic areas onto one breakdown.py legend group."""
    sram_type = sram_type.upper()
    typed_summary = summary.loc[summary["sram_type"].eq(sram_type)].copy()
    typed_components = components.loc[components["sram_type"].eq(sram_type)].copy()
    if typed_summary.empty:
        raise ValueError(f"no summary rows for SRAM type {sram_type}")

    totals = typed_summary.set_index("candidate")["total_area_um2"].astype(float)
    rows = []
    for candidate in CONFIG_PATHS:
        selected = typed_components.loc[typed_components["candidate"].eq(candidate)]
        semantic = {
            name: float(selected[f"{name}_area_um2"].sum())
            for name in PAPER_COMPONENTS
        }
        explicit = {
            category.label: sum(semantic[name] for name in category.components)
            for category in legend_group.categories
            if category.components
        }
        residual_categories = [
            category for category in legend_group.categories if not category.components
        ]
        if len(residual_categories) != 1:
            raise ValueError(
                f"legend group {legend_group.name} must have one residual category"
            )
        residual_label = residual_categories[0].label
        explicit[residual_label] = float(totals.loc[candidate]) - sum(explicit.values())
        if explicit[residual_label] < -1e-3:
            raise ValueError(
                f"{sram_type} {candidate}: legend categories exceed total area"
            )
        explicit[residual_label] = max(0.0, explicit[residual_label])
        for category in legend_group.categories:
            area = explicit[category.label]
            rows.append(
                {
                    "candidate": candidate,
                    "legend_group": legend_group.name,
                    "category": category.label,
                    "sram_type": sram_type,
                    "area_um2": area,
                    "area_mm2": area / 1e6,
                    "total_area_um2": float(totals.loc[candidate]),
                    "percent": area / float(totals.loc[candidate]) * 100.0,
                }
            )
    plot_data = pd.DataFrame(rows)

    plotted_totals = plot_data.groupby("candidate")["area_um2"].sum()
    for candidate, expected in totals.items():
        actual = float(plotted_totals.loc[candidate])
        if abs(actual - float(expected)) > 1e-3:
            raise ValueError(
                f"{sram_type} {candidate}: plotted component sum {actual} "
                f"does not match total area {expected}"
            )
    return plot_data


def write_candidate_breakdown_plot(
    summary: pd.DataFrame,
    components: pd.DataFrame,
    sram_type: str,
    candidate: str,
    output_dir: Path,
    legend_group: area_breakdown.LegendGroup,
) -> tuple[Path, Path]:
    """Write one candidate's normalized stacked-bar CSV/PNG/PDF/SVG."""
    plt = area_breakdown.plt

    plt.rcParams.update(
        {
            "font.size": PLOT_FONT_SIZE,
            "axes.titlesize": PLOT_FONT_SIZE,
            "axes.labelsize": PLOT_FONT_SIZE,
            "xtick.labelsize": PLOT_FONT_SIZE,
            "ytick.labelsize": PLOT_FONT_SIZE,
            "legend.fontsize": PLOT_FONT_SIZE,
            "figure.titlesize": PLOT_FONT_SIZE,
        }
    )

    sram_type = sram_type.upper()
    candidate = candidate.upper()
    if candidate not in CONFIG_PATHS:
        raise ValueError(f"unknown candidate: {candidate}")
    all_plot_data = build_plot_breakdown(
        summary, components, sram_type, legend_group
    )
    plot_data = all_plot_data.loc[
        all_plot_data["candidate"].eq(candidate)
    ].copy()
    stem = (
        f"candidate_area_breakdown_{sram_type.lower()}_{candidate.lower()}"
        f"{legend_group.output_suffix}"
    )
    csv_path = output_dir / f"{stem}.csv"
    png_path = output_dir / f"{stem}.png"
    plot_data.to_csv(csv_path, index=False)

    fig, ax = plt.subplots(figsize=(FIGURE_WIDTH_IN, FIGURE_HEIGHT_IN))
    left = 0.0
    handles = []
    for category in legend_group.categories:
        selected = plot_data.loc[plot_data["category"].eq(category.label)].iloc[0]
        percent = float(selected["percent"])
        ax.barh(
            0,
            percent,
            left=left,
            color=category.color,
            edgecolor="white",
            linewidth=0.3,
            height=0.62,
        )
        if percent >= 5.0:
            ax.text(
                left + percent / 2,
                0,
                f"{percent:.1f}%",
                ha="center",
                va="center",
                fontsize=PLOT_FONT_SIZE,
                fontweight="bold",
                color="white",
            )
        legend_label = (
            f"{category.label} ({percent:.1f}%)"
            if category.show_percent_in_legend
            or category.label.startswith(("DMA", "Misc"))
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
        left += percent

    ax.set_xlim(0.0, 100.0)
    ax.set_ylim(-0.55, 0.55)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.spines[["left", "right", "top", "bottom"]].set_visible(False)
    legend_columns = 3 if candidate == "C4" else 1
    ax.legend(
        handles=handles,
        loc="upper left",
        bbox_to_anchor=(0.0, -0.32, 1.0, 0.2),
        ncol=legend_columns,
        mode="expand" if candidate == "C4" else None,
        frameon=False,
        fontsize=PLOT_FONT_SIZE,
        handlelength=0.9,
        columnspacing=1.0,
        labelspacing=0.5,
        borderaxespad=0.0,
    )
    fig.subplots_adjust(
        left=0.02,
        right=0.985,
        top=0.96,
        bottom=0.58 if candidate == "C4" else 0.70,
    )
    figure_paths = []
    for extension in ("png", "pdf", "svg"):
        figure_path = output_dir / f"{stem}.{extension}"
        fig.savefig(
            figure_path,
            dpi=OUTPUT_DPI,
            facecolor="white",
            bbox_inches="tight",
            pad_inches=0.0,
        )
        figure_paths.append(figure_path)
    plt.close(fig)
    print(f"Wrote {csv_path}")
    for figure_path in figure_paths:
        print(f"Wrote {figure_path}")
    return csv_path, png_path


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    sram_types = ("HS", "HD") if args.sram_type == "both" else (args.sram_type,)
    candidate_options = candidate_options_from_args(args)
    summary, components, audit = get_top_areas(
        c3_report=args.c3_report,
        c4_report=args.c4_report,
        tcu_report=args.tcu_report,
        memory_csv=args.memory_csv,
        sram_types=sram_types,
        candidate_options=candidate_options,
        naive_acc=args.naive_acc,
        naive_acc_report=args.naive_acc_report,
    )

    output_dir = resolve_path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    summary.to_csv(output_dir / "candidate_area_summary.csv", index=False)
    components.to_csv(output_dir / "candidate_area_components.csv", index=False)
    audit.to_csv(output_dir / "sram_replacements.csv", index=False)

    if args.plot:
        for sram_type in sram_types:
            for candidate in CONFIG_PATHS:
                for legend_group in area_breakdown.LEGEND_GROUPS:
                    write_candidate_breakdown_plot(
                        summary,
                        components,
                        sram_type,
                        candidate,
                        output_dir,
                        legend_group,
                    )

    _print_summary(summary)
    print(f"Wrote area estimates to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
