#!/usr/bin/env python3
"""Extract output-double-buffering evidence from a core-0 XRT-VCS FSDB."""

from __future__ import annotations

import argparse
import json

from fsdb_cli.api import report


CYCLE_PS = 10_000


def as_int(value: str) -> int | None:
    if not value or any(char in value.lower() for char in "xz"):
        return None
    return int(value, 2)


def bit(value: str, index: int) -> int | None:
    number = as_int(value)
    return None if number is None else ((number >> index) & 1)


def decode_wait(command: str, dependency: int) -> tuple[int, int, int] | None:
    """Decode waits[dependency] from the packed 538-bit gemm_unified_cmd_t."""
    number = as_int(command)
    if number is None:
        return None
    # notify occupies bits [37:0].  Each wait is {valid, reg_id[3:0], target[31:0]}.
    base = 38 + 37 * dependency
    valid = (number >> (base + 36)) & 1
    reg_id = (number >> (base + 32)) & 0xF
    target = (number >> base) & 0xFFFF_FFFF
    return valid, reg_id, target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fsdb")
    args = parser.parse_args()

    base = (
        "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/"
        "g_sockets[0]/socket/g_cores[0]/core/gemm_node"
    )
    paths = {
        "invocation": base + "/u_VX_gemm_ctrl/invocation_active_q",
        "compute_busy": base + "/u_VX_gemm_unit_v2/compute_group_busy[1:0]",
        "output_conflict": base + "/u_VX_gemm_unit_v2/output_group_conflict",
        "output_fire": base + "/u_VX_gemm_unit_v2/output_read_fire",
        "output_bank": base + "/u_VX_gemm_unit_v2/output_read_bank[1:0]",
        "output_pending": base + "/u_VX_gemm_unit_v2/output_read_valid",
        "output_req_valid": base + "/o_gemm_bus_if/req_valid",
        "output_req_ready": base + "/o_gemm_bus_if/req_ready",
        "inflight_empty": base + "/u_VX_gemm_ctrl/child_inflight_empty_v[4:0]",
        "queue_empty": base + "/u_VX_gemm_ctrl/child_q_empty_v[4:0]",
        "deps_ready": base + "/u_VX_gemm_ctrl/child_deps_ready_v[4:0]",
        "quiescent": base + "/u_VX_gemm_ctrl/scheduler_quiescent",
        "store_issue": base + "/u_VX_gemm_ctrl/u_VX_gemm_fsm/o_store_issue_q[31:0]",
        "copy_issue0": base + "/u_VX_gemm_ctrl/u_VX_gemm_fsm/acc_copy_issue_q[0][31:0]",
        "copy_issue1": base + "/u_VX_gemm_ctrl/u_VX_gemm_fsm/acc_copy_issue_q[1][31:0]",
        "rid_o": base + "/u_VX_gemm_ctrl/effective_sync[4][31:0]",
        "rid_acc0": base + "/u_VX_gemm_ctrl/effective_sync[9][31:0]",
        "rid_acc1": base + "/u_VX_gemm_ctrl/effective_sync[10][31:0]",
        "child0_cmd": base + "/u_VX_gemm_ctrl/g_child_scheduler[0]/child_q_dout[537:0]",
        "child3_cmd": base + "/u_VX_gemm_ctrl/g_child_scheduler[3]/child_q_dout[537:0]",
    }
    events = report(args.fsdb, list(paths.values())).events()

    def value(event, name: str) -> str:
        return event.values.get(paths[name], "")

    active_ps = {
        name: 0
        for name in (
            "invocation",
            "mxu",
            "acc2lmem",
            "dma_st",
            "mxu_acc2lmem_overlap",
            "mxu_dma_st_overlap",
            "rid_acc_free_wait",
            "rid_o_wait",
            "same_group_conflict_block",
            "different_group_opportunity",
            "different_group_accepted",
            "same_group_accepted",
            "output_read_fire",
        )
    }
    accepted_windows = []
    terminal = None
    previous_quiescent = ""

    for event, next_event in zip(events, events[1:]):
        dt = next_event.time - event.time
        invocation_active = value(event, "invocation") == "1"
        quiescent = value(event, "quiescent")

        if invocation_active and quiescent == "1" and previous_quiescent != "1":
            terminal = {
                "time_ps": event.time,
                "dma_st_issued": as_int(value(event, "store_issue")),
                "rid_o_completed": as_int(value(event, "rid_o")),
                "acc_copy_issued": [
                    as_int(value(event, "copy_issue0")),
                    as_int(value(event, "copy_issue1")),
                ],
                "rid_acc_free_completed": [
                    as_int(value(event, "rid_acc0")),
                    as_int(value(event, "rid_acc1")),
                ],
                "child_queue_empty_mask": value(event, "queue_empty"),
                "child_inflight_empty_mask": value(event, "inflight_empty"),
                "compute_group_busy": value(event, "compute_busy"),
            }
        previous_quiescent = quiescent

        if not invocation_active:
            continue
        active_ps["invocation"] += dt

        compute_busy = as_int(value(event, "compute_busy"))
        mxu_active = compute_busy not in (None, 0)
        acc2lmem_active = bit(value(event, "inflight_empty"), 3) == 0
        dma_st_active = bit(value(event, "inflight_empty"), 4) == 0
        output_bank = as_int(value(event, "output_bank"))
        output_group = None if output_bank is None else ((output_bank >> 1) & 1)
        same_group_busy = (
            output_group is not None
            and compute_busy is not None
            and ((compute_busy >> output_group) & 1) == 1
        )
        different_group = mxu_active and not same_group_busy

        if mxu_active:
            active_ps["mxu"] += dt
        if acc2lmem_active:
            active_ps["acc2lmem"] += dt
        if dma_st_active:
            active_ps["dma_st"] += dt
        if mxu_active and acc2lmem_active:
            active_ps["mxu_acc2lmem_overlap"] += dt
        if mxu_active and dma_st_active:
            active_ps["mxu_dma_st_overlap"] += dt
        if value(event, "output_conflict") == "1":
            active_ps["same_group_conflict_block"] += dt

        output_fire = value(event, "output_fire") == "1"
        if output_fire:
            active_ps["output_read_fire"] += dt
            if same_group_busy:
                active_ps["same_group_accepted"] += dt
            elif different_group:
                active_ps["different_group_accepted"] += dt
                accepted_windows.append(
                    {
                        "time_ps": event.time,
                        "compute_group_busy": value(event, "compute_busy"),
                        "output_group": output_group,
                    }
                )

        opportunity = (
            value(event, "output_req_valid") == "1"
            and value(event, "output_pending") == "0"
            and different_group
        )
        if opportunity:
            active_ps["different_group_opportunity"] += dt

        child0_nonempty = bit(value(event, "queue_empty"), 0) == 0
        child3_nonempty = bit(value(event, "queue_empty"), 3) == 0
        if child0_nonempty:
            wait = decode_wait(value(event, "child0_cmd"), 3)
            if wait is not None and wait[0] and wait[1] in (9, 10):
                completed = as_int(value(event, "rid_acc0" if wait[1] == 9 else "rid_acc1"))
                if completed is not None and completed < wait[2]:
                    active_ps["rid_acc_free_wait"] += dt
        if child3_nonempty:
            wait = decode_wait(value(event, "child3_cmd"), 0)
            if wait is not None and wait[0] and wait[1] == 4:
                completed = as_int(value(event, "rid_o"))
                if completed is not None and completed < wait[2]:
                    active_ps["rid_o_wait"] += dt

    cycles = {name: duration // CYCLE_PS for name, duration in active_ps.items()}
    result = {
        "cycle_ps": CYCLE_PS,
        "cycles": cycles,
        "ratios_percent": {
            "acc_drain_hidden_by_mxu": round(
                100.0 * cycles["mxu_acc2lmem_overlap"] / cycles["acc2lmem"], 3
            ),
            "dma_hidden_by_mxu": round(
                100.0 * cycles["mxu_dma_st_overlap"] / cycles["dma_st"], 3
            ),
        },
        "different_group_accepted_windows": accepted_windows,
        "terminal_quiescent_snapshot": terminal,
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
