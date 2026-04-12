"""FSDB Terminal Analyzer.

Both CLI and programmatic entry points are supported.
"""

from fsdb_cli.api import (
    active_time,
    CsvReport,
    cut,
    events,
    find_signals,
    first_high_window,
    hierarchy,
    info,
    metric_latency,
    metric_stall,
    metric_state,
    report,
    signal_ratio,
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
    "cut",
    "events",
    "find_signals",
    "first_high_window",
    "hierarchy",
    "info",
    "metric_latency",
    "metric_stall",
    "metric_state",
    "report",
    "signal_ratio",
]
