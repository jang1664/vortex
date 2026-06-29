from __future__ import annotations

import re
from pathlib import Path
from typing import Any


FPGA_CYCLE_COLUMNS = [
    "fpga_cycle_samples",
    "fpga_cycle_min",
    "fpga_cycle_avg",
    "fpga_cycle_max",
    "fpga_cycle_p50",
    "fpga_cycle_p95",
    "fpga_cycle",
    "fpga_cycle_parse_error",
]

_PERF_CYCLES_RE = re.compile(r"^PERF:\s+instrs=(\d+),\s+cycles=(\d+),\s+IPC=([-+0-9.eE]+)\s*$")
_PERF_BEGIN_RE = re.compile(r"^\[bench-perf\]\s+iteration=(\d+)/(\d+)\s+begin\s*$")
_PERF_END_RE = re.compile(r"^\[bench-perf\]\s+iteration=(\d+)/(\d+)\s+end\s*$")


def empty_fpga_cycle_stats(parse_error: str = "") -> dict[str, Any]:
    return {
        "fpga_cycle_samples": "",
        "fpga_cycle_min": "",
        "fpga_cycle_avg": "",
        "fpga_cycle_max": "",
        "fpga_cycle_p50": "",
        "fpga_cycle_p95": "",
        "fpga_cycle": "",
        "fpga_cycle_parse_error": parse_error,
    }


def _nearest_rank(sorted_values: list[int], q: float) -> int:
    idx = int(q * (len(sorted_values) - 1) + 0.5)
    if idx >= len(sorted_values):
        idx = len(sorted_values) - 1
    return sorted_values[idx]


def _average(values: list[int]) -> int | float:
    avg = sum(values) / len(values)
    return int(avg) if avg.is_integer() else avg


def _stats(values: list[int]) -> dict[str, Any]:
    if not values:
        return empty_fpga_cycle_stats("missing_fpga_cycle")
    ordered = sorted(values)
    p50 = _nearest_rank(ordered, 0.50)
    p95 = _nearest_rank(ordered, 0.95)
    return {
        "fpga_cycle_samples": len(values),
        "fpga_cycle_min": ordered[0],
        "fpga_cycle_avg": _average(values),
        "fpga_cycle_max": ordered[-1],
        "fpga_cycle_p50": p50,
        "fpga_cycle_p95": p95,
        "fpga_cycle": p50,
        "fpga_cycle_parse_error": "",
    }


def _extract_core_cycles(line: str) -> int | None:
    match = _PERF_CYCLES_RE.match(line.strip())
    if not match:
        return None
    return int(match.group(2))


def parse_fpga_cycle_stats(log_file: Path) -> dict[str, Any]:
    if not log_file.exists():
        return empty_fpga_cycle_stats("missing_log_file")
    if not log_file.is_file():
        return empty_fpga_cycle_stats("invalid_log_file")

    marked_cycles: list[int] = []
    legacy_cycles: list[int] = []
    inside_marked_block = False
    current_block_cycle: int | None = None
    saw_marked_block = False

    with log_file.open(errors="replace") as fp:
        for raw_line in fp:
            line = raw_line.strip()
            if _PERF_BEGIN_RE.match(line):
                saw_marked_block = True
                inside_marked_block = True
                current_block_cycle = None
                continue
            if _PERF_END_RE.match(line):
                if inside_marked_block and current_block_cycle is not None:
                    marked_cycles.append(current_block_cycle)
                inside_marked_block = False
                current_block_cycle = None
                continue

            cycle = _extract_core_cycles(line)
            if cycle is None:
                continue
            if inside_marked_block:
                current_block_cycle = cycle
            else:
                legacy_cycles.append(cycle)

    if saw_marked_block:
        return _stats(marked_cycles)
    return _stats(legacy_cycles)
