"""Metric analyzers for FSDB signal data.

Computes performance metrics from parsed fsdbreport value-change data.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Event:
    """A single value-change event."""
    time: int
    values: dict[str, str]  # signal_name -> value


def events_from_csv(
    signal_names: list[str],
    data_rows: list[list[str]],
) -> list[Event]:
    """Convert parsed CSV rows into a sorted list of Events.

    Each Event carries the full signal state at that timestamp by carrying
    forward previous values.
    """
    if not data_rows:
        return []

    events: list[Event] = []
    current_values: dict[str, str] = {}

    for row in data_rows:
        if not row:
            continue
        timestamp = int(row[0])
        for i, name in enumerate(signal_names):
            if i + 1 < len(row):
                value = row[i + 1].strip()
                if value != "":
                    current_values[name] = value
        events.append(Event(time=timestamp, values=dict(current_values)))

    return events


def handshake_latency(
    events: list[Event],
    req_signal: str,
    ack_signal: str,
    req_edge: str = "rising",
) -> list[int]:
    """Measure latency from req edge to ack assertion.

    Args:
        events: Sorted event list.
        req_signal: Request signal full path.
        ack_signal: Acknowledge signal full path.
        req_edge: 'rising' (0→1) or 'falling' (1→0).

    Returns:
        List of latency values in time units.
    """
    latencies = []
    pending_time = None

    def _is_active(val: str, prev: str | None) -> bool:
        if req_edge == "rising":
            return val in ("1", "1'b1") and (prev is None or prev in ("0", "1'b0", "x", "z"))
        else:
            return val in ("0", "1'b0") and (prev is None or prev in ("1", "1'b1", "x", "z"))

    prev_req = None
    for ev in events:
        req_val = ev.values.get(req_signal, "")
        ack_val = ev.values.get(ack_signal, "")

        if pending_time is not None:
            if ack_val in ("1", "1'b1"):
                latencies.append(ev.time - pending_time)
                pending_time = None

        if _is_active(req_val, prev_req):
            pending_time = ev.time

        prev_req = req_val

    return latencies


def stall_ratio(
    events: list[Event],
    valid_signal: str,
    ready_signal: str,
    total_time: int | None = None,
) -> float:
    """Compute the stall ratio: fraction of time valid=1 and ready=0.

    Args:
        events: Sorted event list.
        valid_signal: Valid signal path.
        ready_signal: Ready signal path.
        total_time: Total observation window. If None, derived from events.

    Returns:
        Stall ratio between 0.0 and 1.0.
    """
    if len(events) < 2:
        return 0.0

    if total_time is None:
        total_time = events[-1].time - events[0].time
    if total_time == 0:
        return 0.0

    stall_time = 0
    for i in range(len(events) - 1):
        ev = events[i]
        valid = ev.values.get(valid_signal, "0") in ("1", "1'b1")
        ready = ev.values.get(ready_signal, "0") in ("1", "1'b1")
        if valid and not ready:
            stall_time += events[i + 1].time - ev.time

    return stall_time / total_time


def state_residency(
    events: list[Event],
    state_signal: str,
    total_time: int | None = None,
) -> dict[str, float]:
    """Compute the fraction of time spent in each state value.

    Args:
        events: Sorted event list.
        state_signal: FSM state signal path.
        total_time: Total observation window. If None, derived from events.

    Returns:
        Dict mapping state value to residency ratio (0.0 to 1.0).
    """
    if len(events) < 2:
        return {}

    if total_time is None:
        total_time = events[-1].time - events[0].time
    if total_time == 0:
        return {}

    residency: dict[str, int] = {}
    for i in range(len(events) - 1):
        ev = events[i]
        state_val = ev.values.get(state_signal, "?")
        duration = events[i + 1].time - ev.time
        residency[state_val] = residency.get(state_val, 0) + duration

    return {k: v / total_time for k, v in sorted(residency.items())}
