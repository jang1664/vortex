"""Metric analyzers for FSDB signal data.

Computes performance metrics from parsed fsdbreport value-change data.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass
class Event:
    """A single value-change event."""
    time: int
    values: dict[str, str]  # signal_name -> value


Predicate = Callable[[Event], bool]
Evaluator = Callable[[Event], str | int | bool]


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


def _normalize_derived_value(value: str | int | bool) -> str:
    """Normalize a derived signal value into FSDB-style string form."""
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def derive_signal(
    events: list[Event],
    signal_name: str,
    evaluator: Evaluator,
) -> list[Event]:
    """Return a new event list with a derived signal added.

    Args:
        events: Source event list.
        signal_name: Name/path to assign to the derived signal.
        evaluator: Function mapping an event to the derived value.

    Returns:
        New event list with ``signal_name`` added to ``Event.values``.
    """
    derived_events = []
    for ev in events:
        derived_values = dict(ev.values)
        derived_values[signal_name] = _normalize_derived_value(evaluator(ev))
        derived_events.append(Event(time=ev.time, values=derived_values))
    return derived_events


def count_where(events: list[Event], predicate: Predicate) -> int:
    """Count events that satisfy a predicate."""
    return sum(1 for ev in events if predicate(ev))


def active_time_where(
    events: list[Event],
    predicate: Predicate,
) -> int:
    """Return total time during which a predicate is true.

    The predicate is evaluated on the carried-forward value state of each event
    and charged until the next timestamp.
    """
    if len(events) < 2:
        return 0

    total = 0
    for i in range(len(events) - 1):
        ev = events[i]
        if predicate(ev):
            total += events[i + 1].time - ev.time
    return total


def transition_count(
    events: list[Event],
    signal: str,
    from_values: tuple[str, ...] | None = None,
    to_values: tuple[str, ...] | None = None,
) -> int:
    """Count transitions on a signal, optionally filtering source/target values."""
    if len(events) < 2:
        return 0

    prev = events[0].values.get(signal, "")
    count = 0
    for ev in events[1:]:
        cur = ev.values.get(signal, "")
        if cur != prev:
            from_ok = from_values is None or prev in from_values
            to_ok = to_values is None or cur in to_values
            if from_ok and to_ok:
                count += 1
        prev = cur
    return count


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
