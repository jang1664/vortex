#!/usr/bin/env python3
"""FSDB checks for the bank-conflict, burst, and local-latency hypotheses."""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path

import fsdb_cli as fsdb


ROOT = Path(__file__).resolve().parent
CORE = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/"
    "g_sockets[0]/socket/g_cores[0]/core"
)
PERIOD_PS = 10_000
WINDOWS = {
    "improve": ("76445ns", "80565ns"),
    "naive": ("79365ns", "91965ns"),
}
WAVES = {
    name: str(ROOT / "runs" / name / "vcs_cosim.fsdb")
    for name in WINDOWS
}


def accepted_cycle_times(events, valid: str, ready: str) -> list[int]:
    result = []
    for current, following in zip(events, events[1:]):
        if current.values[valid] == "1" and current.values[ready] == "1":
            result.extend(range(current.time, following.time, PERIOD_PS))
    return result


def input_response_latency() -> dict:
    interfaces = {
        "improve": f"{CORE}/gemm_node/u_tmem_subsystem/ldma_to_switch[0]",
        "naive": f"{CORE}/gemm_node_naive/i_dma_lmem_wide_bus_if",
    }
    result = {}
    for name, interface in interfaces.items():
        bt, et = WINDOWS[name]
        req_valid = f"{interface}/req_valid"
        req_ready = f"{interface}/req_ready"
        rsp_valid = f"{interface}/rsp_valid"
        rsp_ready = f"{interface}/rsp_ready"
        events = fsdb.events(
            WAVES[name],
            [req_valid, req_ready, rsp_valid, rsp_ready],
            bt=bt,
            et=et,
        )
        requests = accepted_cycle_times(events, req_valid, req_ready)
        responses = accepted_cycle_times(events, rsp_valid, rsp_ready)
        if len(requests) != len(responses):
            raise RuntimeError(
                f"{name}: request/response count mismatch "
                f"({len(requests)} != {len(responses)})"
            )
        latencies = [
            (response - request) // PERIOD_PS
            for request, response in zip(requests, responses)
        ]
        ordered = sorted(latencies)
        result[name] = {
            "samples": len(latencies),
            "min_cycles": min(latencies),
            "median_cycles": ordered[len(ordered) // 2],
            "average_cycles": round(sum(latencies) / len(latencies), 5),
            "max_cycles": max(latencies),
            "distribution": dict(sorted(Counter(latencies).items())),
        }
    return result


def lmem_bank_conflicts() -> dict:
    signal = f"{CORE}/mem_unit/local_mem/perf_bank_stalls"
    result = {}
    for name, (bt, et) in WINDOWS.items():
        events = fsdb.events(WAVES[name], [signal], bt=bt, et=et)
        values = [int(event.values[signal], 2) for event in events]
        result[name] = values[-1] - values[0]
    return result


def improve_axi_read_bursts() -> dict:
    bt, et = WINDOWS["improve"]
    base = f"{CORE}/gemm_node/u_tmem_subsystem"
    burst_beats = []
    response_beats = 0
    per_channel = {}
    for channel in range(8):
        interface = f"{base}/axi_m[{channel}]"
        ar_valid = f"{interface}/ar_valid"
        ar_ready = f"{interface}/ar_ready"
        ar_len = f"{interface}/ar_len[7:0]"
        r_valid = f"{interface}/r_valid"
        r_ready = f"{interface}/r_ready"
        events = fsdb.events(
            WAVES["improve"],
            [ar_valid, ar_ready, ar_len, r_valid, r_ready],
            bt=bt,
            et=et,
        )
        channel_bursts = []
        channel_responses = 0
        for current, following in zip(events, events[1:]):
            duration = (following.time - current.time) // PERIOD_PS
            if current.values[ar_valid] == "1" and current.values[ar_ready] == "1":
                channel_bursts.extend(
                    [int(current.values[ar_len], 2) + 1] * duration
                )
            if current.values[r_valid] == "1" and current.values[r_ready] == "1":
                channel_responses += duration
        burst_beats.extend(channel_bursts)
        response_beats += channel_responses
        per_channel[str(channel)] = {
            "transactions": len(channel_bursts),
            "burst_length_distribution": dict(
                sorted(Counter(channel_bursts).items())
            ),
            "response_beats": channel_responses,
        }
    return {
        "transactions": len(burst_beats),
        "burst_length_distribution": dict(sorted(Counter(burst_beats).items())),
        "expected_response_beats": sum(burst_beats),
        "observed_response_beats": response_beats,
        "per_channel": per_channel,
    }


def main() -> None:
    print(json.dumps({
        "lmem_bank_conflict_events": lmem_bank_conflicts(),
        "input_request_to_response": input_response_latency(),
        "improve_axi_read_bursts": improve_axi_read_bursts(),
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
