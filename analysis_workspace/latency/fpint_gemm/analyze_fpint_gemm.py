#!/usr/bin/env python3
"""Reproduce the FSDB measurements used by this directory's analysis.

Run from the repository root with:
    PYTHONPATH=tools python3 analysis_workspace/latency/fpint_gemm/analyze_fpint_gemm.py
"""

from __future__ import annotations

import json
from pathlib import Path

import fsdb_cli as fsdb


REPO_ROOT = Path(__file__).resolve().parents[3]
RUN_ROOT = Path(__file__).resolve().parent / "runs"
CLOCK_PERIOD_PS = 10_000
CORE = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/"
    "g_sockets[0]/socket/g_cores[0]/core"
)

CASES = {
    "improve": {
        "fsdb": RUN_ROOT / "improve/vcs_cosim.fsdb",
        "node": f"{CORE}/gemm_node",
        "ctrl": "u_VX_gemm_ctrl",
        "fsm": "u_VX_gemm_fsm",
        "bus_prefixes": {
            "input": "i_gemm_bus_if",
            "weight": "w_gemm_bus_if",
            "scale_zero": "sz_gemm_bus_if",
        },
        "window_ns": (76_445, 80_565),
    },
    "naive": {
        "fsdb": RUN_ROOT / "naive/vcs_cosim.fsdb",
        "node": f"{CORE}/gemm_node_naive",
        "ctrl": "u_VX_gemm_ctrl_naive",
        "fsm": "u_VX_gemm_fsm_naive",
        "bus_prefixes": {
            "input": "i_dma_gemm_bus_if",
            "weight": "w_dma_gemm_bus_if",
            "scale_zero": "sz_dma_gemm_bus_if",
        },
        "window_ns": (79_365, 91_965),
    },
}

CONTROL_INTERFACES = {
    "weight": "weight_dma_ctrl_if",
    "quant": "quant_param_dma_ctrl_if",
    "input": "input_dma_ctrl_if",
    "gemm": "gemm_unit_if",
}


def cycles(duration_ps: int | float) -> int:
    return round(duration_ps / CLOCK_PERIOD_PS)


def active_cycles(events, predicate) -> int:
    return cycles(fsdb.active_time_where(events, predicate))


def active_intervals(events, predicate, window_start_ps: int) -> list[list[int]]:
    intervals = []
    for current, following in zip(events, events[1:]):
        if predicate(current):
            start = cycles(current.time - window_start_ps)
            duration = cycles(following.time - current.time)
            intervals.append([start, start + duration, duration])
    return intervals


def analyze_case(name: str, case: dict) -> dict:
    wave = str(case["fsdb"])
    node = case["node"]
    ctrl = f'{node}/{case["ctrl"]}'
    start_ns, end_ns = case["window_ns"]
    start_ps = start_ns * 1_000
    bt, et = f"{start_ns}ns", f"{end_ns}ns"

    state_signal = f'{ctrl}/{case["fsm"]}/state_q[7:0]'
    _, state_times = fsdb.metric_state(wave, state_signal, bt=bt, et=et)
    state_cycles = {
        state: cycles(duration)
        for state, duration in sorted(
            state_times.items(), key=lambda item: item[1], reverse=True
        )
    }

    queue_full = f"{ctrl}/parent_q_full"
    queue_events = fsdb.events(wave, [queue_full], bt=bt, et=et)
    queue_full_cycles = active_cycles(
        queue_events, lambda event: event.values[queue_full] == "1"
    )

    buses = {}
    for bus_name, bus_prefix in case["bus_prefixes"].items():
        valid = f"{node}/{bus_prefix}/req_valid"
        ready = f"{node}/{bus_prefix}/req_ready"
        events = fsdb.events(wave, [valid, ready], bt=bt, et=et)
        fired = lambda event, v=valid, r=ready: (
            event.values[v] == "1" and event.values[r] == "1"
        )
        stalled = lambda event, v=valid, r=ready: (
            event.values[v] == "1" and event.values[r] == "0"
        )
        buses[bus_name] = {
            "accepted_cycles": active_cycles(events, fired),
            "stalled_cycles": active_cycles(events, stalled),
            "accepted_intervals": active_intervals(events, fired, start_ps),
        }

    command_latencies = {}
    for interface_name, interface in CONTROL_INTERFACES.items():
        _, samples = fsdb.metric_latency(
            wave,
            f"{node}/{interface}/start",
            f"{node}/{interface}/done",
            bt=bt,
            et=et,
        )
        command_latencies[interface_name] = {
            "samples_cycles": [cycles(sample) for sample in samples],
            "sum_cycles": sum(cycles(sample) for sample in samples),
        }

    window_cycles = (end_ns - start_ns) * 1_000 // CLOCK_PERIOD_PS
    return {
        "fsdb": str(case["fsdb"].relative_to(REPO_ROOT)),
        "fsm_window_ns": [start_ns, end_ns],
        "fsm_window_cycles": window_cycles,
        "parent_queue_full_cycles": queue_full_cycles,
        "parent_queue_full_percent": round(100 * queue_full_cycles / window_cycles, 2),
        "state_residency_cycles": state_cycles,
        "bus_requests": buses,
        "command_latency": command_latencies,
    }


def main() -> None:
    results = {name: analyze_case(name, case) for name, case in CASES.items()}
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
