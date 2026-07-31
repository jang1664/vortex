#!/usr/bin/env python3
"""Print the FINISH Figure 11 resource table from a utilization CSV."""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

RESOURCE_NAMES = ("lut", "ff", "bram", "uram", "dsp")
RESOURCE_LABELS = {
    "lut": "LUT",
    "ff": "FF",
    "bram": "BRAM",
    "uram": "URAM",
    "dsp": "DSP",
}
U55C_CAPACITY = {
    "lut": 1_303_680.0,
    "ff": 2_607_360.0,
    "bram": 2_016.0,
    "uram": 960.0,
    "dsp": 9_024.0,
}
FIGURE_11_ORDER = (
    "GEMM",
    "LMEM/TMEM/CACHE",
    "DMA",
    "SIMT",
    "MISC",
    "Total design",
)
REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_CSV = REPO_ROOT / "build" / "util.csv"


@dataclass(frozen=True)
class ResourceUsage:
    component: str
    values: dict[str, float]


def figure_11_component(category: str) -> str:
    """Map CSV category names to the component labels used in Figure 11."""
    normalized = " ".join(category.strip().lower().split())
    if normalized.startswith("total"):
        return "Total design"
    if "mxu" in normalized or "gemm" in normalized:
        return "GEMM"
    if any(token in normalized for token in ("cache", "lmem", "tmem")):
        return "LMEM/TMEM/CACHE"
    if normalized.startswith("dma"):
        return "DMA"
    if normalized.startswith("simt"):
        return "SIMT"
    if normalized.startswith("misc"):
        return "MISC"
    raise ValueError(f"unrecognized Figure 11 category: {category!r}")


def _parse_resource(row: dict[str, str], resource: str, row_number: int) -> float:
    raw_value = str(row.get(resource, "")).strip().replace(",", "")
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(
            f"row {row_number}: invalid {resource.upper()} value {raw_value!r}"
        ) from exc
    if not math.isfinite(value) or value < 0:
        raise ValueError(
            f"row {row_number}: {resource.upper()} must be finite and nonnegative"
        )
    if value > U55C_CAPACITY[resource]:
        raise ValueError(
            f"row {row_number}: {resource.upper()} usage {value} exceeds "
            f"U55C capacity {U55C_CAPACITY[resource]}"
        )
    return value


def load_utilization(csv_path: Path) -> dict[str, ResourceUsage]:
    """Load, validate, and relabel one Vivado utilization breakdown CSV."""
    with csv_path.open(newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file)
        required = {"category", *RESOURCE_NAMES}
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise ValueError(
                f"{csv_path} is missing required columns: {sorted(missing)}"
            )

        usage_by_component: dict[str, ResourceUsage] = {}
        for row_number, row in enumerate(reader, start=2):
            component = figure_11_component(row["category"])
            if component in usage_by_component:
                raise ValueError(
                    f"row {row_number}: duplicate component {component!r}"
                )
            usage_by_component[component] = ResourceUsage(
                component=component,
                values={
                    resource: _parse_resource(row, resource, row_number)
                    for resource in RESOURCE_NAMES
                },
            )

    missing_components = set(FIGURE_11_ORDER) - set(usage_by_component)
    extra_components = set(usage_by_component) - set(FIGURE_11_ORDER)
    if missing_components or extra_components:
        details = []
        if missing_components:
            details.append(f"missing={sorted(missing_components)}")
        if extra_components:
            details.append(f"extra={sorted(extra_components)}")
        raise ValueError("invalid Figure 11 component set: " + ", ".join(details))

    group_components = tuple(
        component for component in FIGURE_11_ORDER if component != "Total design"
    )
    total = usage_by_component["Total design"]
    for resource in RESOURCE_NAMES:
        group_sum = sum(
            usage_by_component[component].values[resource]
            for component in group_components
        )
        if not math.isclose(
            group_sum,
            total.values[resource],
            rel_tol=0.0,
            abs_tol=0.05,
        ):
            raise ValueError(
                f"{resource.upper()} group sum {group_sum:g} does not match "
                f"Total design {total.values[resource]:g}"
            )

    return usage_by_component


def _format_count(value: float) -> str:
    if value.is_integer():
        return f"{int(value):,}"
    return f"{value:,.1f}"


def format_resource_cell(resource: str, value: float) -> str:
    """Format a raw count and its percentage of the U55C device."""
    percentage = value / U55C_CAPACITY[resource] * 100.0
    return f"{_format_count(value)} ({percentage:.2f}%)"


def render_figure_11_table(usage_by_component: dict[str, ResourceUsage]) -> str:
    """Render the Figure 11 values as a copy-friendly Markdown table."""
    headers = ["Component", *(RESOURCE_LABELS[name] for name in RESOURCE_NAMES)]
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for component in FIGURE_11_ORDER:
        usage = usage_by_component[component]
        cells = [
            component,
            *(
                format_resource_cell(resource, usage.values[resource])
                for resource in RESOURCE_NAMES
            ),
        ]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Print Figure 11 resource counts and percentages of total "
            "Alveo U55C capacity."
        )
    )
    parser.add_argument(
        "csv_path",
        nargs="?",
        type=Path,
        default=DEFAULT_CSV,
        help=f"utilization CSV (default: {DEFAULT_CSV})",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    csv_path = args.csv_path.expanduser().resolve()
    usage = load_utilization(csv_path)
    print(f"Source: {csv_path}")
    print("Percentages are relative to total Alveo U55C capacity.")
    print(render_figure_11_table(usage))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
