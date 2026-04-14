"""FSDB Terminal Analyzer.

Both CLI and programmatic entry points are supported.
"""

from fsdb_cli.api import (
    active_time,
    active_time_where,
    count_where,
    CsvReport,
    cut,
    derive_signal,
    events,
    find_signals,
    first_high_window,
    hierarchy,
    info,
    load_csv,
    metric_latency,
    metric_stall,
    metric_state,
    report,
    signal_ratio,
    transition_count,
)
from fsdb_cli.analyzers import Event
from fsdb_cli.parsers import FsdbInfo, ScopeNode, VarInfo

__all__ = [
    "CsvReport",
    "Event",
    "FsdbInfo",
    "ScopeNode",
    "VarInfo",
    "active_time",
    "active_time_where",
    "count_where",
    "cut",
    "derive_signal",
    "events",
    "find_signals",
    "first_high_window",
    "hierarchy",
    "info",
    "load_csv",
    "metric_latency",
    "metric_stall",
    "metric_state",
    "report",
    "signal_ratio",
    "transition_count",
]
