#!/usr/bin/env python3
"""Summarize the pipelined misaligned global DMA from an xrt-vcs FSDB."""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))

from fsdb_cli import api as fsdb  # noqa: E402


CLOCK_PS = 10_000
DMA = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/"
    "g_sockets[0]/socket/g_cores[0]/core/u_VX_dma_node/u_dma_unit/"
    "g_misaligned/u_impl"
)


def cycles(duration_ps: int) -> int:
    return duration_ps // CLOCK_PS


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fsdb", type=Path)
    parser.add_argument("--slots", type=int, choices=(2, 4, 8), default=8)
    args = parser.parse_args()

    occupancy_width = (args.slots + 1).bit_length() - 1
    if (1 << occupancy_width < args.slots + 1):
        occupancy_width += 1
    occupancy_bits = f"{occupancy_width - 1}:0"

    residency_leaves = [
        "state[1:0]",
        "rd_state[1:0]",
        "wr_state[1:0]",
        f"slot_occupancy_r[{occupancy_bits}]",
        f"rd_outstanding_limit[{occupancy_bits}]",
        "dcache_req_pending_r[2:0]",
        "lmem_req_pending_r[2:0]",
    ]
    pulse_leaves = [
        "src_req_issue_fire",
        "src_req_fire",
        "src_rsp_fire",
        "dst_req_issue_fire",
        "dst_req_fire",
        "pack_move_fire",
    ]
    leaves = residency_leaves + pulse_leaves
    signals = [f"{DMA}/{leaf}" for leaf in leaves]
    report = fsdb.report(str(args.fsdb), signals)
    events = report.events()

    residency: dict[tuple[str, str], int] = defaultdict(int)
    for event, next_event in zip(events, events[1:]):
        duration = next_event.time - event.time
        for signal in signals:
            residency[(signal, event.values.get(signal, ""))] += duration

    print(f"FSDB: {args.fsdb}")
    print(f"time unit: {report.time_unit}, events: {len(events)}")
    for leaf in residency_leaves:
        signal = f"{DMA}/{leaf}"
        values = sorted(
            (value, cycles(duration))
            for (name, value), duration in residency.items()
            if name == signal and duration and "x" not in value.lower()
        )
        print(f"{leaf}: {values}")

    for leaf in pulse_leaves:
        signal = f"{DMA}/{leaf}"
        print(f"{leaf}: {cycles(residency[(signal, '1')])} active cycles")

    state = f"{DMA}/state[1:0]"
    src_issue = f"{DMA}/src_req_issue_fire"
    pack_move = f"{DMA}/pack_move_fire"
    overlap_ps = 0
    for event, next_event in zip(events, events[1:]):
        if (
            event.values.get(state) == "S_RUN"
            and event.values.get(src_issue) == "1"
            and event.values.get(pack_move) == "1"
        ):
            overlap_ps += next_event.time - event.time
    print(f"read-generation/pack overlap: {cycles(overlap_ps)} cycles")


if __name__ == "__main__":
    main()
