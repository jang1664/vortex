#!/usr/bin/env python3
"""Summarize DBG_TRACE_GEMM_CMD_PERF structured simulation records."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


MARKER_RE = re.compile(
    r"\b(GEMM_CMD_PERF_SUMMARY|GEMM_CMD_CLASS_SUMMARY|"
    r"GEMM_CMD_TIMELINE|GEMM_CMD_OVERLAP_PAIR|GEMM_TILE_OVERLAP|"
    r"TMEM_DMA_CMD_PERF)\s*\|\s*\{([^}]*)\}"
)


def parse_value(value: str) -> object:
    value = value.strip()
    try:
        return int(value, 0)
    except ValueError:
        return value


def parse_fields(body: str) -> dict[str, object]:
    result: dict[str, object] = {}
    for item in body.split(","):
        key, separator, value = item.strip().partition("=")
        if not separator:
            raise ValueError(f"malformed structured field: {item!r}")
        result[key.strip()] = parse_value(value)
    return result


@dataclass
class TraceData:
    label: str
    summaries: list[dict[str, object]] = field(default_factory=list)
    classes: list[dict[str, object]] = field(default_factory=list)
    commands: list[dict[str, object]] = field(default_factory=list)
    pairs: list[dict[str, object]] = field(default_factory=list)
    tiles: list[dict[str, object]] = field(default_factory=list)
    dma: list[dict[str, object]] = field(default_factory=list)


def read_trace(path: Path, label: str) -> TraceData:
    trace = TraceData(label=label)
    destinations = {
        "GEMM_CMD_PERF_SUMMARY": trace.summaries,
        "GEMM_CMD_CLASS_SUMMARY": trace.classes,
        "GEMM_CMD_TIMELINE": trace.commands,
        "GEMM_CMD_OVERLAP_PAIR": trace.pairs,
        "GEMM_TILE_OVERLAP": trace.tiles,
        "TMEM_DMA_CMD_PERF": trace.dma,
    }
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            match = MARKER_RE.search(line)
            if not match:
                continue
            try:
                record = parse_fields(match.group(2))
            except ValueError as error:
                raise ValueError(f"{path}:{line_number}: {error}") from error
            record["workload"] = label
            destinations[match.group(1)].append(record)
    validate_trace(path, trace)
    return trace


def validate_trace(path: Path, trace: TraceData) -> None:
    if not trace.summaries:
        raise ValueError(f"{path}: no GEMM_CMD_PERF_SUMMARY record")
    for summary in trace.summaries:
        emitted = int(summary["emitted"])
        issued = int(summary["issued"])
        completed = int(summary["completed"])
        incomplete = int(summary["incomplete"])
        if emitted != issued or issued != completed or incomplete:
            raise ValueError(
                f"{path}: lifecycle accounting mismatch: "
                f"emitted={emitted}, issued={issued}, "
                f"completed={completed}, incomplete={incomplete}"
            )
    for command in trace.commands:
        emit = int(command["emit"])
        issue = int(command["issue"])
        done = int(command["done"])
        if not emit <= issue <= done:
            raise ValueError(
                f"{path}: invalid UID {command.get('uid')} interval "
                f"{emit} <= {issue} <= {done}"
            )
        if int(command["overlap_any"]) > done - issue:
            raise ValueError(
                f"{path}: UID {command.get('uid')} overlap exceeds service"
            )


def union_columns(records: Iterable[dict[str, object]]) -> list[str]:
    columns: list[str] = []
    for record in records:
        for key in record:
            if key not in columns:
                columns.append(key)
    return columns


def write_csv(path: Path, records: list[dict[str, object]]) -> None:
    columns = union_columns(records)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(records)


def markdown_report(traces: list[TraceData]) -> str:
    lines = [
        "# GEMM Command Overlap Summary",
        "",
        "## Workloads",
        "",
        "| Workload | Cycles | Commands | Max logical concurrency | "
        "Compute pipeline cycles |",
        "|---|---:|---:|---:|---:|",
    ]
    for trace in traces:
        for summary in trace.summaries:
            lines.append(
                f"| {trace.label} | {summary['cycles']} | {summary['emitted']} | "
                f"{summary['max_concurrent']} | "
                f"{summary['compute_pipeline_cycles']} |"
            )

    lines.extend(
        [
            "",
            "## Tile overlap",
            "",
            "All values are raw cycles. Logical command overlap does not imply "
            "simultaneous DMA descriptor execution.",
            "",
            "| Workload | Tile | Preload-next ∩ compute | Preload tail | "
            "Ready slack | Store ∩ next compute | Store ∩ next load | "
            "Store ∩ any later load | Store tail | Final store drain |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for trace in traces:
        for tile in trace.tiles:
            lines.append(
                f"| {trace.label} | {tile['tile']} | "
                f"{tile['preload_next_compute']} | {tile['preload_tail']} | "
                f"{tile['tile_ready_slack']} | {tile['store_next_compute']} | "
                f"{tile['store_next_load']} | {tile['store_later_load']} | "
                f"{tile['store_tail']} | {tile['final_store_drain']} |"
            )
    return "\n".join(lines) + "\n"


def parse_input(value: str) -> tuple[str, Path]:
    label, separator, path = value.partition("=")
    if separator:
        return label, Path(path)
    parsed_path = Path(value)
    return parsed_path.stem, parsed_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        metavar="[LABEL=]LOG",
        help="structured simulation log; repeat for workload comparison",
    )
    parser.add_argument(
        "--out-prefix",
        type=Path,
        required=True,
        help="output prefix for _commands.csv, _pairs.csv, and _summary.md",
    )
    args = parser.parse_args()

    traces = [read_trace(path, label) for label, path in map(parse_input, args.input)]
    commands = [record for trace in traces for record in trace.commands]
    pairs = [record for trace in traces for record in trace.pairs]
    dma = [record for trace in traces for record in trace.dma]
    write_csv(Path(f"{args.out_prefix}_commands.csv"), commands)
    write_csv(Path(f"{args.out_prefix}_pairs.csv"), pairs)
    write_csv(Path(f"{args.out_prefix}_dma.csv"), dma)
    Path(f"{args.out_prefix}_summary.md").write_text(
        markdown_report(traces), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
