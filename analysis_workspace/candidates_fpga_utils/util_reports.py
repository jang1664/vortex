"""Read FPGA utilization reports and choose reports from one exact build."""

from __future__ import annotations

from dataclasses import dataclass, field
from fnmatch import fnmatchcase
import math
from pathlib import Path
import re

RESOURCES = ("LUT", "FF", "DSP", "BRAM", "URAM")
U55C_CAPACITY = dict(zip(RESOURCES, (1_303_680, 2_607_360, 9_024, 2_016, 960)))
# Keep these patterns consistent with vortex_util::category_specs in export_util.tcl.
CATEGORY_PATTERNS = {
    "SIMT": tuple(f"*/execute/{unit}_unit" for unit in ("alu", "lsu", "fpu", "sfu", "tcu"))
    + tuple(f"*/{name}" for name in ("issue", "schedule", "fetch", "commit", "decode", "dcr_data", "u_VX_dma_node")),
    "Cache/LMEM/TMEM": (
        "*/mem_unit/local_mem", "*/dcache", "*/icache", "*/l2cache", "*/l3cache",
        "*/gemm_node/u_tmem_subsystem/g_bank*.u_bank",
    ),
    "MXU": ("*/gemm_node/u_VX_gemm_unit",),
    "DMA": (
        "*/gemm_node/u_tmem_subsystem/u_dma_engine",
        *(f"*/gemm_node/u_tmem_subsystem/u_ldma_{name}" for name in ("input", "output", "sz", "weight")),
        "*/gemm_node/u_tmem_dma_ctrl",
    ),
}
CATEGORIES = (*CATEGORY_PATTERNS, "Misc", "Total Vortex_axi")
SITE_RESOURCES = {
    "CLB LUTs": "LUT", "Slice LUTs": "LUT",
    "CLB Registers": "FF", "Slice Registers": "FF",
    "DSPs": "DSP", "DSP48E2": "DSP", "Block RAM Tile": "BRAM", "URAM": "URAM",
}


@dataclass
class Report:
    path: Path
    header: dict[str, str] = field(default_factory=dict)
    totals: dict[str, float] = field(default_factory=dict)
    capacity: dict[str, float] = field(default_factory=dict)
    hierarchy: dict[str, dict[str, float]] = field(default_factory=dict)


@dataclass
class Analysis:
    report: Report
    stage: str
    fallback: bool
    values: dict[str, dict[str, float]]
    capacity: dict[str, float]
    notes: list[str] = field(default_factory=list)
    checkpoint: Path | None = None


def number(value: str) -> float:
    # Hierarchical percentages can use a partition's capacity; read only the count.
    match = re.fullmatch(r"\s*([\d,]+(?:\.\d+)?)(?:\([^)]*%\))?\s*", value)
    if not match:
        raise ValueError(f"invalid utilization count: {value!r}")
    result = float(match[1].replace(",", ""))
    if not math.isfinite(result):
        raise ValueError(f"non-finite utilization count: {value!r}")
    return result


def read_report(path: Path) -> Report:
    report = Report(path.resolve())
    hierarchy_columns: dict[str, int] = {}
    site_columns: dict[str, int] = {}
    parents: dict[int, str] = {}
    hierarchy_closed = False
    with path.open(encoding="utf-8-sig") as stream:
        for lineno, line in enumerate(stream, 1):
            if line.startswith("+") and report.hierarchy:
                hierarchy_closed = True
            if not line.startswith("|"):
                continue
            metadata = re.fullmatch(r"\|\s*([^|:]+):\s*([^|]*?)\s*\|?", line.strip())
            if metadata:
                report.header[metadata[1].strip()] = metadata[2].strip()
                continue
            raw = line.rstrip("\r\n").split("|")[1:-1]
            cells = [cell.strip() for cell in raw]
            if len(cells) == 1 and ":" in cells[0]:
                key, value = cells[0].split(":", 1)
                report.header[key.strip()] = value.strip()
                continue
            if cells and cells[0] == "Site Type":
                site_columns = {name: i for i, name in enumerate(cells)}
                hierarchy_columns = {}
                continue
            if cells and cells[0] == "Instance":
                hierarchy_columns = {name: i for i, name in enumerate(cells)}
                site_columns = {}
                required = {"Total LUTs", "FFs", "RAMB36", "RAMB18", "URAM", "DSP Blocks"}
                if not required <= hierarchy_columns.keys():
                    raise ValueError(f"{path}:{lineno}: missing hierarchy resource columns")
                continue
            try:
                if site_columns and cells:
                    resource = SITE_RESOURCES.get(cells[0].rstrip("*").strip())
                    if resource and resource not in report.totals:
                        report.totals[resource] = number(cells[site_columns["Used"]])
                        report.capacity[resource] = number(cells[site_columns["Available"]])
                if not hierarchy_columns or not cells:
                    continue
                name = cells[0]
                # Parenthesized instance names report local-only usage, not a subtree.
                if not name or name.startswith("("):
                    continue
                hierarchy_closed = False
                instance = raw[0][1:] if raw[0].startswith(" ") else raw[0]
                indent = len(instance) - len(instance.lstrip())
                if indent % 2:
                    raise ValueError(f"odd hierarchy indentation for {name!r}")
                depth = indent // 2
                if depth and depth - 1 not in parents:
                    raise ValueError(f"missing hierarchy parent for {name!r}")
                parent = parents.get(depth - 1, "")
                # Reports scoped to one cell can repeat the selected root.
                path_name = name if not depth else parent if parent == name else f"{parent}/{name}"
                parents = {level: value for level, value in parents.items() if level < depth}
                parents[depth] = path_name
                def count(column: str) -> float:
                    return number(cells[hierarchy_columns[column]])
                values = {
                    "LUT": count("Total LUTs"), "FF": count("FFs"),
                    "DSP": count("DSP Blocks"), "BRAM": count("RAMB36") + count("RAMB18") / 2,
                    "URAM": count("URAM"),
                }
                if path_name in report.hierarchy and report.hierarchy[path_name] != values:
                    raise ValueError(f"conflicting hierarchy rows for {path_name}")
                report.hierarchy[path_name] = values
            except (ValueError, IndexError, KeyError) as exc:
                raise ValueError(f"{path}:{lineno}: {exc}") from exc
    if report.hierarchy and not hierarchy_closed:
        raise ValueError(f"{path}: incomplete hierarchy table")
    return report


def device_capacity(report: Report) -> dict[str, float]:
    if set(report.capacity) == set(RESOURCES) and all(value > 0 for value in report.capacity.values()):
        return report.capacity.copy()
    if report.header.get("Device", "").lower().startswith("xcu55c"):
        return U55C_CAPACITY.copy()
    raise ValueError(f"no full-device capacity for {report.header.get('Device', 'unknown device')}")


def full_total(report: Report) -> dict[str, float]:
    # OOC kernel and pblock reports cannot stand in for the full FPGA design.
    if report.header.get("Design") != "level0_wrapper":
        raise ValueError("report does not cover the full level0_wrapper design")
    if "-cells" in report.header.get("Command", "") or "-pblocks" in report.header.get("Command", ""):
        raise ValueError("scoped report cannot supply full-FPGA utilization")
    if set(report.totals) == set(RESOURCES):
        return report.totals.copy()
    if "level0_wrapper" in report.hierarchy:
        return report.hierarchy["level0_wrapper"].copy()
    raise ValueError("missing full-design resource counts")


def breakdown(report: Report) -> dict[str, dict[str, float]]:
    roots = [path for path in report.hierarchy if path.rsplit("/", 1)[-1] == "vortex_axi"]
    if len(roots) != 1:
        raise ValueError(f"expected one vortex_axi hierarchy root, found {len(roots)}")
    base = roots[0]
    descendants = {path: values for path, values in report.hierarchy.items() if path.startswith(base + "/")}
    if not descendants:
        raise ValueError("hierarchy report has no Vortex_axi descendants")
    depth_match = re.search(r"-hierarchical_depth\s+(\d+)", report.header.get("Command", ""))
    if depth_match:
        # A limited-depth report can hide categories while still having a valid total.
        depth = int(depth_match[1])
        deepest_needed = base.count("/") + 4
        if depth < deepest_needed:
            raise ValueError("hierarchy report depth is too shallow for the category patterns")
    values: dict[str, dict[str, float]] = {}
    claimed: list[tuple[str, str]] = []
    for category, patterns in CATEGORY_PATTERNS.items():
        matched = sorted((path for path in descendants if any(fnmatchcase(path, pattern) for pattern in patterns)), key=len)
        roots_for_category: list[str] = []
        for path in matched:
            if any(path.startswith(root + "/") for root in roots_for_category):
                continue
            for previous, owner in claimed:
                if path == previous or path.startswith(previous + "/") or previous.startswith(path + "/"):
                    raise ValueError(f"overlapping categories {owner} and {category}: {previous}, {path}")
            roots_for_category.append(path)
            claimed.append((path, category))
        values[category] = {resource: sum(descendants[path][resource] for path in roots_for_category) for resource in RESOURCES}
    if not claimed:
        raise ValueError("no known categories matched the Vortex_axi hierarchy")
    total = report.hierarchy[base]
    values["Misc"] = {}
    for resource in RESOURCES:
        remainder = total[resource] - sum(values[category][resource] for category in CATEGORY_PATTERNS)
        if remainder < -0.001:
            raise ValueError(f"categorized {resource} exceeds the Vortex_axi total")
        values["Misc"][resource] = max(0.0, remainder)
    values["Total Vortex_axi"] = total.copy()
    return values


def implementation_dir(build: Path) -> Path:
    return build / "_x/link/vivado/vpl/prj/prj.runs/impl_1"


def report_candidates(build: Path, action: str) -> list[tuple[Path, str]]:
    binary = build / "bin"
    exported = build / "_x/reports/link/imp"
    impl = implementation_dir(build)
    hierarchy = [(binary / "hier_utilization.rpt", "pre_opt"), (impl / "hier_utilization.rpt", "pre_opt")]
    if action == "breakdown":
        result = list(hierarchy)
        # Only inspect reports from this build's implementation, never unrelated IP synthesis.
        for parent in (binary, exported, impl):
            for path in sorted(parent.glob("*util*.rpt")):
                name = path.name.removeprefix("impl_1_")
                stage = "routed" if "routed" in name else "placed" if "placed" in name else "linked" if "init_" in name else "unknown"
                result.append((path, stage))
    else:
        result = []
        for name, stage in (
            ("full_util_routed.rpt", "routed"), ("full_util_placed.rpt", "placed"),
            ("hw_bb_locked_utilization_placed.rpt", "placed"), ("init_report_utilization_0.rpt", "linked"),
        ):
            result.extend(((binary / f"impl_1_{name}", stage), (exported / f"impl_1_{name}", stage), (impl / name, stage)))
        result.extend(hierarchy)
    seen: set[Path] = set()
    unique = []
    for path, stage in result:
        if path not in seen:
            unique.append((path, stage))
            seen.add(path)
    return unique


def analyze_report(path: Path, action: str, stage: str, fallback: bool) -> Analysis:
    report = read_report(path)
    values = {"Full FPGA": full_total(report)} if action == "total" else breakdown(report)
    return Analysis(report, stage, fallback, values, device_capacity(report))


def select_report(build: Path, action: str) -> tuple[Analysis | None, list[str]]:
    notes = []
    for index, (path, stage) in enumerate(report_candidates(build, action)):
        if not path.is_file():
            continue
        try:
            analysis = analyze_report(path, action, stage, index != 0)
            if analysis.fallback:
                notes.insert(0, f"Preferred report unavailable or invalid; using {stage} report {path}")
            analysis.notes = notes
            return analysis, notes
        except (OSError, ValueError) as exc:
            notes.append(f"Rejected {path}: {exc}")
    return None, notes


def checkpoint_candidates(build: Path, action: str) -> list[tuple[Path, str]]:
    impl = implementation_dir(build)
    result = [(impl / f"level0_wrapper_{suffix}.dcp", suffix) for suffix in (
        "postroute_physopt", "routed", "physopt", "placed", "opt",
    )]
    # A failing placement can still leave a complete logical implementation checkpoint.
    result.insert(4, (impl / "post_place_fail_fast.dcp", "placed"))
    if action == "breakdown":
        result.append((impl.parent / "ulp_vortex_afu_1_0_synth_1/ulp_vortex_afu_1_0.dcp", "synth"))
    return [(path, stage) for path, stage in result if path.is_file()]
