"""Programmatic API for FSDB analysis.

This module exposes the same functionality as the CLI in importable form so
Jupyter notebooks and Python scripts can reuse the backend/parsing logic
without shelling out through the CLI entry point.
"""

from __future__ import annotations

from dataclasses import dataclass

from fsdb_cli.analyzers import (
    Event,
    events_from_csv,
    handshake_latency,
    stall_ratio,
    state_residency,
)
from fsdb_cli.backends import (
    run_fsdbdebug,
    run_fsdbextract,
    run_fsdbreport,
    run_fsdbreport_file,
)
from fsdb_cli.parsers import (
    FsdbInfo,
    ScopeNode,
    parse_csv_report,
    parse_fsdb_info,
    parse_full_tree,
    parse_scope_tree,
    parse_tree_vars,
)


@dataclass
class CsvReport:
    """Structured fsdbreport CSV output."""

    time_unit: str
    signal_names: list[str]
    data_rows: list[list[str]]

    def events(self) -> list[Event]:
        """Convert the CSV rows into value-carried-forward events."""
        return events_from_csv(self.signal_names, self.data_rows)


def info(fsdb: str) -> FsdbInfo:
    """Return FSDB metadata."""
    raw = run_fsdbdebug(["-info"], fsdb)
    return parse_fsdb_info(raw)


def hierarchy(fsdb: str, scopes_only: bool = True) -> ScopeNode:
    """Return the parsed hierarchy tree."""
    if scopes_only:
        raw = run_fsdbdebug(["-scope"], fsdb)
        return parse_scope_tree(raw)
    raw = run_fsdbdebug(["-tree"], fsdb)
    return parse_full_tree(raw)


def find_signals(fsdb: str, pattern: str):
    """Return signal metadata entries whose name contains a regex pattern."""
    import re

    raw = run_fsdbdebug(["-tree"], fsdb)
    all_vars = parse_tree_vars(raw)
    regex = re.compile(pattern, re.IGNORECASE)
    return [v for v in all_vars if regex.search(v.name)]


def cut(
    fsdb: str,
    scope: str | None = None,
    level: int | None = None,
    bt: str | None = None,
    et: str | None = None,
    output: str | None = None,
) -> str:
    """Extract a smaller FSDB and return backend output text."""
    return run_fsdbextract(
        fsdb=fsdb,
        scope=scope,
        level=level,
        bt=bt,
        et=et,
        output=output,
    )


def report(
    fsdb: str,
    signals: list[str],
    bt: str | None = None,
    et: str | None = None,
) -> CsvReport:
    """Return parsed fsdbreport CSV content for the requested signals."""
    raw = run_fsdbreport_file(fsdb, signals, bt=bt, et=et)
    time_unit, signal_names, data_rows = parse_csv_report(raw)
    return CsvReport(
        time_unit=time_unit,
        signal_names=signal_names,
        data_rows=data_rows,
    )


def events(
    fsdb: str,
    signals: list[str],
    bt: str | None = None,
    et: str | None = None,
) -> list[Event]:
    """Convenience wrapper returning value-carried-forward events."""
    return report(fsdb, signals, bt=bt, et=et).events()


def metric_latency(
    fsdb: str,
    req_signal: str,
    ack_signal: str,
    bt: str | None = None,
    et: str | None = None,
) -> tuple[str, list[int]]:
    """Return time unit and req->ack latency samples."""
    rep = report(fsdb, [req_signal, ack_signal], bt=bt, et=et)
    return rep.time_unit, handshake_latency(rep.events(), req_signal, ack_signal)


def metric_stall(
    fsdb: str,
    valid_signal: str,
    ready_signal: str,
    bt: str | None = None,
    et: str | None = None,
) -> tuple[str, float]:
    """Return time unit and valid/ready stall ratio."""
    rep = report(fsdb, [valid_signal, ready_signal], bt=bt, et=et)
    return rep.time_unit, stall_ratio(rep.events(), valid_signal, ready_signal)


def metric_state(
    fsdb: str,
    signal: str,
    bt: str | None = None,
    et: str | None = None,
) -> tuple[str, dict[str, float]]:
    """Return time unit and state residency map."""
    rep = report(fsdb, [signal], bt=bt, et=et)
    return rep.time_unit, state_residency(rep.events(), signal)


def signal_ratio(
    fsdb: str,
    numerator_signal: str,
    denominator_signal: str,
    bt: str | None = None,
    et: str | None = None,
    active_values: tuple[str, ...] = ("1", "1'b1"),
) -> float:
    """Return time(numerator active)/time(denominator active) within a window."""
    evs = events(fsdb, [numerator_signal, denominator_signal], bt=bt, et=et)
    if len(evs) < 2:
        return 0.0

    num_time = 0
    den_time = 0
    for i in range(len(evs) - 1):
        ev = evs[i]
        dt = evs[i + 1].time - ev.time
        if ev.values.get(denominator_signal, "0") in active_values:
            den_time += dt
            if ev.values.get(numerator_signal, "0") in active_values:
                num_time += dt
    return 0.0 if den_time == 0 else (num_time / den_time)


def active_time(
    fsdb: str,
    signal: str,
    bt: str | None = None,
    et: str | None = None,
    active_values: tuple[str, ...] = ("1", "1'b1"),
) -> int:
    """Return the total active time for a signal within a window."""
    evs = events(fsdb, [signal], bt=bt, et=et)
    if len(evs) < 2:
        return 0

    total = 0
    for i in range(len(evs) - 1):
        ev = evs[i]
        if ev.values.get(signal, "0") in active_values:
            total += evs[i + 1].time - ev.time
    return total


def first_high_window(
    fsdb: str,
    signal: str,
    active_values: tuple[str, ...] = ("1", "1'b1"),
) -> tuple[int, int] | None:
    """Return the first contiguous active window for a signal as (bt, et) in ps."""
    evs = events(fsdb, [signal])
    if len(evs) < 2:
        return None

    start = None
    for i in range(len(evs) - 1):
        ev = evs[i]
        nxt = evs[i + 1]
        is_active = ev.values.get(signal, "0") in active_values
        if start is None and is_active:
            start = ev.time
        if start is not None and not is_active:
            return (start, ev.time)
        if start is not None and nxt.values.get(signal, "0") not in active_values and is_active:
            return (start, nxt.time)

    if start is not None:
        return (start, evs[-1].time)
    return None
