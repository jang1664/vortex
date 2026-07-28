"""Compare naive and improved Vortex_axi area with a scaled naive LMEM.

The synthesis report for the naive design uses a 1 MiB, 32-bank LMEM.  This
script estimates a 768 KiB version by keeping the bank count and all non-macro
logic unchanged while scaling only the LMEM SRAM macro area by 768 / 1024.
This is intentionally a first-order depth-scaling estimate; it does not assume
that a particular 3072-depth compiled SRAM macro exists.

The output table contains parent and child hierarchy rows for diagnosis, so its
rows are not additive.  Delta is always ``improve - adjusted naive``.

Example:

    python analysis_workspace/top_breakdown/compare_naive_improve.py
"""

import argparse
import csv
import math
import re
from pathlib import Path
from typing import Dict, List, NamedTuple, Pattern, Tuple, Union


HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]

DEFAULT_NAIVE_REPORT = VORTEX / (
    "build/hw/syn/synopsys/top_analysis/"
    "Vortex_axi_naive_gemm_th32_tcol32_hwexp_dcache/top/reports/"
    "14_Vortex_axi.mapped.area.rpt"
)
DEFAULT_IMPROVE_REPORT = VORTEX / (
    "build/hw/syn/synopsys/top_analysis/"
    "Vortex_axi_improve_th32_tcol32_hwexp_dcache/top/reports/"
    "14_Vortex_axi.mapped.area.rpt"
)
DEFAULT_OUTPUT = HERE / "naive_vs_improve_768k.csv"

HIERARCHY_ROW_RE = re.compile(
    r"^(\S+)\s+"
    r"([0-9]+(?:\.[0-9]+)?)\s+"
    r"([0-9]+(?:\.[0-9]+)?)\s+"
    r"([0-9]+(?:\.[0-9]+)?)\s+"
    r"([0-9]+(?:\.[0-9]+)?)\s+"
    r"([0-9]+(?:\.[0-9]+)?)"
    r"(?:\s+(\S+))?\s*$"
)


class HierarchyRow(NamedTuple):
    path: str
    area: float
    local_comb: float
    local_noncomb: float
    local_macro: float
    design: str


class AreaReport(NamedTuple):
    path: Path
    total_cell_area: float
    combinational_area: float
    noncombinational_area: float
    macro_area: float
    hierarchy: Dict[str, HierarchyRow]


class ComponentSpec(NamedTuple):
    name: str
    pattern: Pattern[str]
    adjust_for_lmem: bool = False


COMPONENTS = (
    ComponentSpec("Vortex hierarchy", re.compile(r"^vortex$"), True),
    ComponentSpec(
        "Core",
        re.compile(r"/g_cores_\d+__core$"),
        True,
    ),
    ComponentSpec(
        "GEMM node",
        re.compile(r"/gemm_node(?:_naive)?$"),
    ),
    ComponentSpec(
        "Memory unit",
        re.compile(r"/mem_unit$"),
        True,
    ),
    ComponentSpec(
        "Local memory hierarchy",
        re.compile(r"/mem_unit/local_mem$"),
        True,
    ),
    ComponentSpec("DMA node", re.compile(r"/u_VX_dma_node$")),
    ComponentSpec("Execute", re.compile(r"/execute$")),
    ComponentSpec("Issue", re.compile(r"/issue$")),
    ComponentSpec("Schedule", re.compile(r"/schedule$")),
    ComponentSpec("Fetch", re.compile(r"/fetch$")),
    ComponentSpec("Commit", re.compile(r"/commit$")),
    ComponentSpec("Decode", re.compile(r"/decode$")),
    ComponentSpec("DCR data", re.compile(r"/dcr_data$")),
    ComponentSpec("L1 data cache", re.compile(r"/g_sockets_\d+__socket/dcache$")),
    ComponentSpec(
        "L1 instruction cache",
        re.compile(r"/g_sockets_\d+__socket/icache$"),
    ),
    ComponentSpec("L2 cache", re.compile(r"/g_clusters_\d+__cluster/l2cache$")),
    ComponentSpec("L3 cache", re.compile(r"^vortex/l3cache$")),
    ComponentSpec("AXI adapter", re.compile(r"^axi_adapter$")),
    ComponentSpec("LSU demux", re.compile(r"^u_lsu_demux$")),
    ComponentSpec("HBM AXI muxes", re.compile(r"^g_hbm_mux_\d+__u_axi_mux$")),
    ComponentSpec(
        "HBM LSU mux cuts",
        re.compile(r"^g_hbm_mux_\d+__u_lsu_mux_cut$"),
    ),
)


def resolve_path(path: Path) -> Path:
    return path if path.is_absolute() else VORTEX / path


def summary_value(text: str, label: str) -> float:
    match = re.search(
        rf"^{re.escape(label)}:\s+([0-9]+(?:\.[0-9]+)?)\s*$",
        text,
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(f"missing {label!r} in area report")
    return float(match.group(1))


def load_report(path: Path) -> AreaReport:
    if not path.is_file():
        raise SystemExit(f"area report does not exist: {path}")
    text = path.read_text()
    hierarchy = {}  # type: Dict[str, HierarchyRow]
    for line in text.splitlines():
        match = HIERARCHY_ROW_RE.match(line)
        if not match:
            continue
        path_name = match.group(1)
        hierarchy[path_name] = HierarchyRow(
            path=path_name,
            area=float(match.group(2)),
            local_comb=float(match.group(4)),
            local_noncomb=float(match.group(5)),
            local_macro=float(match.group(6)),
            design=match.group(7) or "",
        )
    if "Vortex_axi" not in hierarchy:
        raise SystemExit(f"hierarchical area table is missing from {path}")
    return AreaReport(
        path=path,
        total_cell_area=summary_value(text, "Total cell area"),
        combinational_area=summary_value(text, "Combinational area"),
        noncombinational_area=summary_value(text, "Noncombinational area"),
        macro_area=summary_value(text, "Macro/Black Box area"),
        hierarchy=hierarchy,
    )


def macro_area_below(report: AreaReport, path_pattern: Pattern[str]) -> float:
    roots = [path for path in report.hierarchy if path_pattern.search(path)]
    if not roots:
        return 0.0
    return sum(
        row.local_macro
        for row in report.hierarchy.values()
        if row.local_macro > 0.0
        and any(row.path.startswith(f"{root}/") for root in roots)
    )


def component_area(report: AreaReport, pattern: Pattern[str]) -> float:
    return sum(
        row.area for row in report.hierarchy.values() if pattern.search(row.path)
    )


def percent(delta: float, baseline: float) -> float:
    return math.nan if baseline == 0.0 else delta / baseline * 100.0


def result_row(
    component: str,
    naive_report_area: float,
    naive_adjusted_area: float,
    improve_area: float,
    note: str = "",
) -> Dict[str, Union[float, str]]:
    delta = improve_area - naive_adjusted_area
    return {
        "component": component,
        "naive_report_area_um2": naive_report_area,
        "naive_768k_estimate_um2": naive_adjusted_area,
        "improve_area_um2": improve_area,
        "delta_improve_minus_naive_768k_um2": delta,
        "delta_percent_vs_naive_768k": percent(delta, naive_adjusted_area),
        "note": note,
    }


def build_rows(
    naive: AreaReport,
    improve: AreaReport,
    current_lmem_kib: float,
    target_lmem_kib: float,
) -> Tuple[List[Dict[str, Union[float, str]]], float, float]:
    scale = target_lmem_kib / current_lmem_kib
    lmem_pattern = re.compile(r"/mem_unit/local_mem$")
    tmem_pattern = re.compile(r"/gemm_node/u_tmem_subsystem$")
    naive_lmem_macro = macro_area_below(naive, lmem_pattern)
    improve_lmem_macro = macro_area_below(improve, lmem_pattern)
    improve_tmem_macro = macro_area_below(improve, tmem_pattern)
    if naive_lmem_macro <= 0.0:
        raise SystemExit("no naive LMEM SRAM macro area was found")

    macro_correction = naive_lmem_macro * (scale - 1.0)
    adjusted_total = naive.total_cell_area + macro_correction
    adjusted_macro = naive.macro_area + macro_correction
    assumption = (
        f"LMEM SRAM macro scaled by {target_lmem_kib:g}/{current_lmem_kib:g}; "
        "bank count and non-macro logic unchanged"
    )

    rows = [
        result_row(
            "Total cell area",
            naive.total_cell_area,
            adjusted_total,
            improve.total_cell_area,
            assumption,
        ),
        result_row(
            "Combinational area",
            naive.combinational_area,
            naive.combinational_area,
            improve.combinational_area,
        ),
        result_row(
            "Noncombinational area",
            naive.noncombinational_area,
            naive.noncombinational_area,
            improve.noncombinational_area,
        ),
        result_row(
            "All SRAM macros",
            naive.macro_area,
            adjusted_macro,
            improve.macro_area,
            assumption,
        ),
        result_row(
            "LMEM SRAM macros",
            naive_lmem_macro,
            naive_lmem_macro * scale,
            improve_lmem_macro,
            assumption,
        ),
        result_row(
            "TMEM SRAM macros",
            0.0,
            0.0,
            improve_tmem_macro,
        ),
    ]

    for spec in COMPONENTS:
        naive_area = component_area(naive, spec.pattern)
        improve_area = component_area(improve, spec.pattern)
        adjusted_area = (
            naive_area + macro_correction if spec.adjust_for_lmem else naive_area
        )
        rows.append(
            result_row(
                spec.name,
                naive_area,
                adjusted_area,
                improve_area,
                assumption if spec.adjust_for_lmem else "",
            )
        )
    return rows, scale, macro_correction


def write_csv(path: Path, rows: List[Dict[str, Union[float, str]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def format_number(value: Union[float, str]) -> str:
    if isinstance(value, str):
        return value
    if math.isnan(value):
        return "n/a"
    return f"{value:,.2f}"


def print_rows(rows: List[Dict[str, Union[float, str]]]) -> None:
    headers = ("Component", "Naive report", "Naive 768K", "Improve", "Delta", "Delta %")
    printable = []
    for row in rows:
        printable.append(
            (
                str(row["component"]),
                format_number(row["naive_report_area_um2"]),
                format_number(row["naive_768k_estimate_um2"]),
                format_number(row["improve_area_um2"]),
                format_number(row["delta_improve_minus_naive_768k_um2"]),
                format_number(row["delta_percent_vs_naive_768k"]),
            )
        )
    widths = [
        max(len(headers[index]), *(len(row[index]) for row in printable))
        for index in range(len(headers))
    ]
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print("  ".join("-" * width for width in widths))
    for row in printable:
        print(
            row[0].ljust(widths[0])
            + "  "
            + "  ".join(
                row[index].rjust(widths[index]) for index in range(1, len(row))
            )
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare naive and improve top area with a scaled naive LMEM."
    )
    parser.add_argument("--naive-report", type=Path, default=DEFAULT_NAIVE_REPORT)
    parser.add_argument("--improve-report", type=Path, default=DEFAULT_IMPROVE_REPORT)
    parser.add_argument(
        "--naive-current-lmem-kib",
        type=float,
        default=1024.0,
        help="LMEM capacity represented by the naive report (default: 1024).",
    )
    parser.add_argument(
        "--naive-target-lmem-kib",
        type=float,
        default=768.0,
        help="Target naive LMEM capacity for linear macro scaling (default: 768).",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.naive_current_lmem_kib <= 0.0 or args.naive_target_lmem_kib <= 0.0:
        raise SystemExit("LMEM capacities must be positive")
    naive_report = resolve_path(args.naive_report)
    improve_report = resolve_path(args.improve_report)
    output = resolve_path(args.output)
    naive = load_report(naive_report)
    improve = load_report(improve_report)
    rows, scale, correction = build_rows(
        naive,
        improve,
        args.naive_current_lmem_kib,
        args.naive_target_lmem_kib,
    )
    write_csv(output, rows)
    print(
        "Naive LMEM macro scaling: "
        f"{args.naive_current_lmem_kib:g} KiB -> "
        f"{args.naive_target_lmem_kib:g} KiB ({scale:.6f}x)"
    )
    print(f"Naive area correction: {correction:,.2f} um^2")
    print("Delta convention: improve - adjusted naive")
    print()
    print_rows(rows)
    print(f"\nWrote {output}")


if __name__ == "__main__":
    main()
