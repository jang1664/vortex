#!/usr/bin/env python3
"""Summarize the GEMM_NAIVE datapath from a GEMM-only FSDB."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools"))

import fsdb_cli as fsdb  # noqa: E402


CLOCK_PS = 10_000
NODE = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/"
    "g_sockets[0]/socket/g_cores[0]/core/gemm_node_naive"
)
FSM = f"{NODE}/u_VX_gemm_ctrl_naive/u_VX_gemm_fsm_naive"
STATE = f"{FSM}/state_q[7:0]"


def is_high(value: str) -> bool:
    return value in ("1", "1'b1")


def parse_sv_int(value: str) -> int | None:
    text = str(value).strip().lower().replace("_", "")
    if not text or any(char in text for char in "xz?"):
        return None
    if "'h" in text:
        return int(text.split("'h", 1)[1], 16)
    if "'b" in text:
        return int(text.split("'b", 1)[1], 2)
    if text.startswith("h"):
        return int(text[1:], 16)
    if text.startswith("b"):
        return int(text[1:], 2)
    if len(text) > 1 and set(text) <= {"0", "1"}:
        return int(text, 2)
    return int(text, 10)


def cycles(duration_ps: int) -> float:
    return duration_ps / CLOCK_PS


def job_window(path: str, allow_partial: bool) -> tuple[int, int, bool]:
    events = fsdb.events(path, [STATE])
    start = None
    for event in events:
        state = event.values.get(STATE, "")
        if start is None and state not in ("", "x", "xxxxxxxx", "S_IDLE"):
            start = event.time
        elif start is not None and state == "S_IDLE":
            return start, event.time, True
    if allow_partial and start is not None:
        return start, events[-1].time, False
    raise RuntimeError("completed non-idle GEMM FSM window was not found")


def active_duration(events, predicate) -> int:
    return fsdb.active_time_where(events, predicate)


def pulse_count(path: str, signal: str, bt: int, et: int) -> int:
    events = fsdb.events(path, [signal], bt=f"{bt}ps", et=f"{et}ps")
    duration = active_duration(events, lambda event: is_high(event.values.get(signal, "0")))
    return round(cycles(duration))


def print_fsm(path: str, bt: int, et: int) -> None:
    _, residency = fsdb.metric_state(path, STATE, bt=f"{bt}ps", et=f"{et}ps")
    print("\nFSM residency (top contributors)")
    for state, ratio in sorted(residency.items(), key=lambda item: item[1], reverse=True):
        if ratio >= 0.001:
            print(f"  {state:<30} {ratio * 100:7.2f}%  {cycles((et - bt) * ratio):9.1f} cycles")


def print_dma(path: str, name: str, bt: int, et: int, prefetch_depth: int = 1) -> None:
    base = f"{NODE}/u_{name}_lmem_dma"
    top_state = f"{base}/top_state[2:0]"
    occupancy = f"{base}/slot_occupancy_r[3:0]"
    ahead_width = max(1, prefetch_depth.bit_length())
    ahead = f"{base}/rd_ahead_count_r[{ahead_width - 1}:0]"
    _, state_res = fsdb.metric_state(path, top_state, bt=f"{bt}ps", et=f"{et}ps")
    _, occ_res = fsdb.metric_state(path, occupancy, bt=f"{bt}ps", et=f"{et}ps")
    _, ahead_res = fsdb.metric_state(path, ahead, bt=f"{bt}ps", et=f"{et}ps")

    print(f"\n{name} local DMA")
    print(
        "  commands={:d}, src_req={:d}, src_rsp={:d}, dst_req={:d}".format(
            pulse_count(path, f"{base}/cmd_start", bt, et),
            pulse_count(path, f"{base}/src_req_fire", bt, et),
            pulse_count(path, f"{base}/src_rsp_fire", bt, et),
            pulse_count(path, f"{base}/dst_req_fire", bt, et),
        )
    )
    state_text = ", ".join(
        f"{state}={ratio * 100:.1f}%"
        for state, ratio in sorted(state_res.items(), key=lambda item: item[1], reverse=True)
        if ratio >= 0.005
    )
    print(f"  top_state: {state_text}")
    occ_text = ", ".join(
        f"{value}={ratio * 100:.1f}%"
        for value, ratio in sorted(occ_res.items(), key=lambda item: item[1], reverse=True)
        if ratio >= 0.005
    )
    print(f"  slot occupancy: {occ_text}")
    ahead_text = ", ".join(
        f"{value}={ratio * 100:.1f}%"
        for value, ratio in sorted(ahead_res.items(), key=lambda item: item[1], reverse=True)
        if ratio >= 0.005
    )
    print(f"  read-ahead: {ahead_text}")


def vector_popcount_stats(path: str, signal: str, bt: int, et: int) -> tuple[float, float, int]:
    events = fsdb.events(path, [signal], bt=f"{bt}ps", et=f"{et}ps")
    total_ones_ps = 0
    max_ones = 0
    for event, nxt in zip(events, events[1:]):
        value = parse_sv_int(event.values.get(signal, "0"))
        ones = 0 if value is None else value.bit_count()
        total_ones_ps += ones * (nxt.time - event.time)
        max_ones = max(max_ones, ones)
    window_ps = et - bt
    average = 0.0 if window_ps == 0 else total_ones_ps / window_ps
    return cycles(total_ones_ps), average, max_ones


def print_weight_gather(path: str, bt: int, et: int) -> None:
    base = f"{NODE}/u_weight_gather_dma"
    slot_busy = f"{base}/slot_busy_r[3:0]"
    lane_req = f"{base}/lane_req_fire[7:0]"
    lane_rsp = f"{base}/lane_rsp_fire[7:0]"
    _, slot_res = fsdb.metric_state(path, slot_busy, bt=f"{bt}ps", et=f"{et}ps")
    req_beats, req_average, req_peak = vector_popcount_stats(path, lane_req, bt, et)
    rsp_beats, rsp_average, rsp_peak = vector_popcount_stats(path, lane_rsp, bt, et)

    print("\nweight local gather DMA")
    print(
        "  commands={:d}, groups_allocated={:d}, groups_retired={:d}".format(
            pulse_count(path, f"{base}/ctrl_if/start", bt, et),
            pulse_count(path, f"{base}/allocate", bt, et),
            pulse_count(path, f"{base}/retire_fire", bt, et),
        )
    )
    print(
        f"  logical-lane req={req_beats:.0f} beats (avg {req_average:.2f}/cycle, peak {req_peak}), "
        f"rsp={rsp_beats:.0f} beats (avg {rsp_average:.2f}/cycle, peak {rsp_peak})"
    )
    slot_text = ", ".join(
        f"{value}={ratio * 100:.1f}%"
        for value, ratio in sorted(slot_res.items(), key=lambda item: item[1], reverse=True)
        if ratio >= 0.005
    )
    print(f"  busy-slot mask: {slot_text}")


def has_weight_gather(path: str, bt: int) -> bool:
    signal = f"{NODE}/u_weight_gather_dma/active_r"
    try:
        report = fsdb.report(path, [signal], bt=f"{bt}ps", et=f"{bt + CLOCK_PS}ps")
        return signal in report.signal_names
    except RuntimeError:
        return False


def print_bus(path: str, label: str, bus: str, bt: int, et: int) -> None:
    valid = f"{NODE}/{bus}/req_valid"
    ready = f"{NODE}/{bus}/req_ready"
    events = fsdb.events(path, [valid, ready], bt=f"{bt}ps", et=f"{et}ps")
    offered_ps = active_duration(events, lambda event: is_high(event.values.get(valid, "0")))
    accepted_ps = active_duration(
        events,
        lambda event: is_high(event.values.get(valid, "0"))
        and is_high(event.values.get(ready, "0")),
    )
    stalled_ps = offered_ps - accepted_ps
    stall_ratio = 0.0 if offered_ps == 0 else stalled_ps / offered_ps
    print(
        f"  {label:<24} accepted={cycles(accepted_ps):8.0f} beats, "
        f"stalled={cycles(stalled_ps):8.0f} cycles ({stall_ratio * 100:5.1f}% of valid)"
    )


def print_compute(path: str, bt: int, et: int) -> None:
    start = f"{NODE}/gemm_unit_if/start"
    done = f"{NODE}/gemm_unit_if/done"
    idle = f"{NODE}/gemm_unit_if/idle"
    events = fsdb.events(path, [idle], bt=f"{bt}ps", et=f"{et}ps")
    busy_ps = active_duration(events, lambda event: not is_high(event.values.get(idle, "0")))
    print("\nGEMM unit")
    print(
        f"  starts={pulse_count(path, start, bt, et)}, "
        f"dones={pulse_count(path, done, bt, et)}, busy={cycles(busy_ps):.0f} cycles "
        f"({busy_ps / (et - bt) * 100:.2f}% of FSM window)"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fsdb", type=Path)
    parser.add_argument("--partial", action="store_true")
    args = parser.parse_args()
    path = str(args.fsdb.resolve())

    bt, et, complete = job_window(path, args.partial)
    print(f"FSDB: {path}")
    status = "complete" if complete else "checkpoint/partial"
    print(f"GEMM FSM window ({status}): {bt}ps .. {et}ps = {cycles(et - bt):.0f} cycles")
    print_fsm(path, bt, et)

    gather = has_weight_gather(path, bt)
    prefetch_depth = 4 if gather else 1
    for name in ("input", "quant_param", "output"):
        print_dma(path, name, bt, et, prefetch_depth)
    if gather:
        print_weight_gather(path, bt, et)
    else:
        print_dma(path, "weight", bt, et)

    print("\nRequest-bus throughput/stall")
    buses = [
        ("input LMEM 64B", "i_dma_lmem_wide_bus_if"),
        ("input GEMM 64B", "i_dma_gemm_bus_if"),
        ("quant LMEM 64B", "sz_dma_lmem_wide_bus_if"),
        ("quant GEMM 64B", "sz_dma_gemm_bus_if"),
        ("output GEMM 64B", "o_dma_gemm_bus_if"),
        ("output LMEM 64B", "o_dma_lmem_wide_bus_if"),
    ]
    if gather:
        buses[2:2] = [("weight GEMM 64B", "w_dma_gemm_bus_if")]
    else:
        buses[2:2] = [
            ("weight LMEM wide 16B", "w_dma_lmem_wide_bus_if"),
            ("weight LMEM lane0 8B", "w_dma_lmem_bus_if"),
            ("weight GEMM 16B", "w_dma_gemm_bus_if"),
        ]
    for label, bus in buses:
        print_bus(path, label, bus, bt, et)

    if gather:
        print("\nWeight logical-lane LMEM stall")
        for lane in range(8):
            print_bus(path, f"weight logical lane {lane}", f"w_lane_mem_if[{lane}]", bt, et)
        print("\nPhysical LMEM lane stall")
        for lane in range(16):
            print_bus(path, f"physical lane {lane}", f"lmem_bus_if[{lane}]", bt, et)

    print_compute(path, bt, et)


if __name__ == "__main__":
    main()
