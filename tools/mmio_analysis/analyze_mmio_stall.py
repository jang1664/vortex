#!/usr/bin/env python3
"""Analyze MMIO write stall behavior on the GEMM stream port vs the regular
LSU memory path.

For each store request that crosses the LSU→GEMM control interface we measure:
  * wait cycles (req_valid asserted, req_ready=0)
  * response latency (req_accept → rsp_valid)
  * acceptance gap (between consecutive req_ready handshakes)

We do the same for the regular cache/lmem path (lsu_mem_if[0]) and compare.
We also report the share of req_valid time blocked by:
  - rsp_holding (single-outstanding gate in u_gemm_job_frontend)
  - occupied_q==0 (no allocated job)
  - issue_if.ready=0 (downstream FIFO blocked)

Run:
    PYTHONPATH=tools python3 tools/mmio_analysis/analyze_mmio_stall.py \
        --fsdb build/sim/xrtsim_vcs/vcs_cosim.fsdb \
        --bt 78us --et 178us
"""
from __future__ import annotations

import argparse
import statistics
import sys
from collections import Counter

sys.path.insert(0, "tools")
import fsdb_cli as fsdb  # noqa: E402

CLK_PS = 10_000  # 100 MHz, period = 10 ns = 10000 ps
HIGH = ("1", "1'b1")
LOW = ("0", "1'b0", "")

CORE = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]"
    "/cluster/g_sockets[0]/socket/g_cores[0]/core"
)
GEMM_REQ_VALID = f"{CORE}/gemm_ctrl_if[0]/req_valid"
GEMM_REQ_READY = f"{CORE}/gemm_ctrl_if[0]/req_ready"
GEMM_RSP_VALID = f"{CORE}/gemm_ctrl_if[0]/rsp_valid"
GEMM_RSP_READY = f"{CORE}/gemm_ctrl_if[0]/rsp_ready"
GEMM_REQ_RW    = f"{CORE}/gemm_ctrl_if[0]/req_data.rw"

LSU_REQ_VALID = f"{CORE}/lsu_mem_if[0]/req_valid"
LSU_REQ_READY = f"{CORE}/lsu_mem_if[0]/req_ready"
LSU_RSP_VALID = f"{CORE}/lsu_mem_if[0]/rsp_valid"
LSU_RSP_READY = f"{CORE}/lsu_mem_if[0]/rsp_ready"

JOB_FE = f"{CORE}/gemm_node/u_gemm_job_frontend"
RSP_HOLDING = f"{JOB_FE}/rsp_holding"
OCCUPIED_Q  = f"{JOB_FE}/occupied_q"


def _is_high(v: str) -> bool:
    return v in HIGH


def collect_handshake_events(events, valid_sig, ready_sig):
    """Walk event stream and return list of dicts:
        {valid_rise, accept_time, gap_to_next_accept}
    A handshake is sampled at every (valid && ready) cycle boundary.
    """
    accepts = []
    last_v = "0"
    last_r = "0"
    valid_start = None  # time when current valid window started
    for i, ev in enumerate(events):
        v = ev.values.get(valid_sig, "0")
        r = ev.values.get(ready_sig, "0")
        # Track when valid first rose for this transaction
        if _is_high(v) and not _is_high(last_v):
            valid_start = ev.time
        if _is_high(v) and _is_high(r):
            accepts.append({"accept_time": ev.time, "valid_start": valid_start})
            # advance valid_start: if v stays high we still get next accept
            valid_start = ev.time  # fresh transaction following
        last_v = v
        last_r = r
    return accepts


def transactions_with_response(events, valid_sig, ready_sig,
                               rsp_valid_sig, rsp_ready_sig):
    """Pair each accepted req with the next rsp_valid&rsp_ready handshake."""
    accepts = collect_handshake_events(events, valid_sig, ready_sig)
    rsps    = collect_handshake_events(events, rsp_valid_sig, rsp_ready_sig)
    rsp_idx = 0
    out = []
    for a in accepts:
        while rsp_idx < len(rsps) and rsps[rsp_idx]["accept_time"] <= a["accept_time"]:
            rsp_idx += 1
        if rsp_idx >= len(rsps):
            break
        rsp_t = rsps[rsp_idx]["accept_time"]
        out.append({
            "valid_start": a["valid_start"],
            "accept": a["accept_time"],
            "rsp": rsp_t,
            "wait_ps": a["accept_time"] - a["valid_start"],
            "rsp_lat_ps": rsp_t - a["accept_time"],
            "round_trip_ps": rsp_t - a["valid_start"],
        })
    return out


def gap_between_accepts(handshakes):
    gaps = []
    for i in range(1, len(handshakes)):
        gaps.append(handshakes[i]["accept"] - handshakes[i - 1]["accept"])
    return gaps


def time_pred(events, predicate):
    """Total time within which predicate(ev) is true."""
    total = 0
    for i in range(len(events) - 1):
        if predicate(events[i]):
            total += events[i + 1].time - events[i].time
    return total


def fmt_cycles(ps: float) -> str:
    return f"{ps / CLK_PS:.2f}cyc ({ps:.0f}ps)"


def hist_cycles(samples_ps, label):
    if not samples_ps:
        print(f"  {label}: no samples")
        return
    cyc = [round(x / CLK_PS) for x in samples_ps]
    c = Counter(cyc)
    n = len(cyc)
    print(f"  {label}: n={n}  mean={statistics.mean(cyc):.2f}cyc  "
          f"median={statistics.median(cyc)}cyc  "
          f"p95={sorted(cyc)[int(n*0.95)] if n>1 else cyc[0]}cyc  "
          f"max={max(cyc)}cyc")
    for v in sorted(c):
        bar = "#" * min(40, c[v] * 40 // n if n else 0)
        print(f"    {v:>3}cyc | {c[v]:>5} {bar}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fsdb", default="build/sim/xrtsim_vcs/vcs_cosim.fsdb")
    ap.add_argument("--bt", default="78us")
    ap.add_argument("--et", default="178us")
    args = ap.parse_args()

    print(f"[FSDB] {args.fsdb}")
    print(f"[Window] {args.bt} .. {args.et}\n")

    print("== GEMM MMIO interface ==")
    gemm_evs = fsdb.events(args.fsdb, [
        GEMM_REQ_VALID, GEMM_REQ_READY,
        GEMM_RSP_VALID, GEMM_RSP_READY,
        GEMM_REQ_RW,
        RSP_HOLDING, OCCUPIED_Q,
    ], bt=args.bt, et=args.et)
    print(f"  events parsed: {len(gemm_evs)}")

    g_tx = transactions_with_response(
        gemm_evs, GEMM_REQ_VALID, GEMM_REQ_READY,
        GEMM_RSP_VALID, GEMM_RSP_READY)
    print(f"  accepted transactions: {len(g_tx)}")
    if g_tx:
        # split writes vs reads via streaming rw scan
        writes, reads = [], []
        rw_cur = "0"
        ev_iter = iter(gemm_evs)
        next_ev = next(ev_iter, None)
        for tx in g_tx:
            while next_ev is not None and next_ev.time <= tx["accept"]:
                rw_cur = next_ev.values.get(GEMM_REQ_RW, rw_cur)
                next_ev = next(ev_iter, None)
            (writes if _is_high(rw_cur) else reads).append(tx)
        print(f"  writes(rw=1): {len(writes)}   reads(rw=0): {len(reads)}")

        hist_cycles([t["wait_ps"] for t in g_tx],
                    "MMIO wait cycles (valid→ready)  ← backpressure on store")
        hist_cycles([t["rsp_lat_ps"] for t in writes],
                    "MMIO write rsp latency (writes only)")
        if reads:
            hist_cycles([t["rsp_lat_ps"] for t in reads],
                        "MMIO read  rsp latency (reads only — make_wait/poll)")
        gaps = gap_between_accepts(g_tx)
        hist_cycles(gaps, "MMIO accept-to-accept gap (kernel issue cadence)")

    # Stall accounting against root-cause signals
    if gemm_evs:
        t_valid = time_pred(gemm_evs, lambda ev: _is_high(ev.values.get(GEMM_REQ_VALID, "0")))
        t_stall = time_pred(gemm_evs,
            lambda ev: _is_high(ev.values.get(GEMM_REQ_VALID, "0"))
                   and not _is_high(ev.values.get(GEMM_REQ_READY, "0")))
        t_stall_holding = time_pred(gemm_evs,
            lambda ev: _is_high(ev.values.get(GEMM_REQ_VALID, "0"))
                   and not _is_high(ev.values.get(GEMM_REQ_READY, "0"))
                   and _is_high(ev.values.get(RSP_HOLDING, "0")))
        t_stall_unallocated = time_pred(gemm_evs,
            lambda ev: _is_high(ev.values.get(GEMM_REQ_VALID, "0"))
                   and not _is_high(ev.values.get(GEMM_REQ_READY, "0"))
                   and not _is_high(ev.values.get(OCCUPIED_Q, "0")))
        t_stall_other = t_stall - t_stall_holding - t_stall_unallocated

        print()
        print("  Stall attribution (within req_valid time):")
        print(f"    req_valid time           : {fmt_cycles(t_valid)}")
        if t_valid:
            print(f"    stalled (valid&!ready)   : {fmt_cycles(t_stall)} "
                  f"= {100*t_stall/t_valid:.1f}% of valid")
            if t_stall:
                print(f"      due to rsp_holding=1   : {fmt_cycles(t_stall_holding)} "
                      f"= {100*t_stall_holding/t_stall:.1f}% of stall")
                print(f"      due to occupied_q=0    : {fmt_cycles(t_stall_unallocated)} "
                      f"= {100*t_stall_unallocated/t_stall:.1f}% of stall")
                print(f"      other (issue_if/queue) : {fmt_cycles(t_stall_other)} "
                      f"= {100*t_stall_other/t_stall:.1f}% of stall")

    print("\n== Regular LSU memory interface (lsu_mem_if[0]) ==")
    lsu_evs = fsdb.events(args.fsdb, [
        LSU_REQ_VALID, LSU_REQ_READY,
        LSU_RSP_VALID, LSU_RSP_READY,
    ], bt=args.bt, et=args.et)
    print(f"  events parsed: {len(lsu_evs)}")
    l_tx = transactions_with_response(
        lsu_evs, LSU_REQ_VALID, LSU_REQ_READY,
        LSU_RSP_VALID, LSU_RSP_READY)
    print(f"  accepted transactions: {len(l_tx)}")
    if l_tx:
        hist_cycles([t["wait_ps"] for t in l_tx],
                    "LSU  wait cycles (valid→ready)")
        hist_cycles([t["rsp_lat_ps"] for t in l_tx],
                    "LSU  rsp latency")
        gaps = gap_between_accepts(l_tx)
        hist_cycles(gaps, "LSU  accept-to-accept gap")

    if lsu_evs:
        t_valid = time_pred(lsu_evs, lambda ev: _is_high(ev.values.get(LSU_REQ_VALID, "0")))
        t_stall = time_pred(lsu_evs,
            lambda ev: _is_high(ev.values.get(LSU_REQ_VALID, "0"))
                   and not _is_high(ev.values.get(LSU_REQ_READY, "0")))
        if t_valid:
            print(f"  LSU req_valid time : {fmt_cycles(t_valid)}  "
                  f"stalled: {fmt_cycles(t_stall)} = {100*t_stall/t_valid:.1f}%")


if __name__ == "__main__":
    main()
