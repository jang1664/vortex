"""Duration profiling between configurable start/end event conditions.

Measures the time between pairs of structured log events that match
user-specified conditions.  Each condition is defined by an event name
and optional payload field constraints with comparison operators.

Supported operators: ``=``, ``!=``, ``>``, ``>=``, ``<``, ``<=``

Example – measure IMCE compute time:

    start = EventCondition("STATE_CHANGE", [("from", "=", "S_IDLE"), ("to", "=", "S_COMPUTE")])
    end   = EventCondition("STATE_CHANGE", [("from", "=", "S_COMPUTE"), ("to", "=", "S_IDLE")])

    profiler = DurationProfiler(log_dir, start, end, file_pattern="*ctrl_pl*")
    profiler.profile_all()
    stats = profiler.get_stats()

CLI match syntax (comma-separated):
    "from=S_IDLE,to=S_COMPUTE"   — exact match
    "addr!=0"                    — not equal
    "count>=5"                   — numeric comparison
"""

import re
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from log_analyzer.log_format import parse_file, LogEntry
from log_analyzer.models import DurationRecord

# Operators ordered longest-first so ">=" is tried before ">"
_OPS = ["!=", ">=", "<=", ">", "<", "="]
_OP_RE = re.compile(r"^(\w+)\s*(!=|>=|<=|>|<|=)\s*(.+)$")


def _to_number(s: str):
    """Try to convert *s* to int (dec or hex). Return str on failure."""
    try:
        return int(s, 0)
    except (ValueError, TypeError):
        return s


def _check_op(actual, op: str, expected) -> bool:
    """Evaluate ``actual <op> expected``."""
    # Coerce both sides to numbers when possible
    a = _to_number(str(actual))
    e = _to_number(str(expected))

    # If both are numeric, compare numerically
    if isinstance(a, int) and isinstance(e, int):
        if op == "=":
            return a == e
        if op == "!=":
            return a != e
        if op == ">":
            return a > e
        if op == ">=":
            return a >= e
        if op == "<":
            return a < e
        if op == "<=":
            return a <= e

    # String comparison (only = and != make sense)
    sa, se = str(actual), str(expected)
    if op == "=":
        return sa == se
    if op == "!=":
        return sa != se
    # For ordering ops on non-numeric values, fall back to string compare
    if op == ">":
        return sa > se
    if op == ">=":
        return sa >= se
    if op == "<":
        return sa < se
    if op == "<=":
        return sa <= se
    return False


def parse_match_expr(s: str) -> list[tuple[str, str, str]]:
    """Parse a comma-separated match expression string.

    Returns list of ``(key, op, value)`` tuples.

    Examples::

        "from=S_IDLE,to=S_COMPUTE"  -> [("from","=","S_IDLE"), ("to","=","S_COMPUTE")]
        "addr!=0,count>=5"          -> [("addr","!=","0"), ("count",">=","5")]
    """
    result = []
    if not s:
        return result
    for token in s.split(","):
        token = token.strip()
        m = _OP_RE.match(token)
        if not m:
            continue
        key, op, value = m.group(1), m.group(2), m.group(3).strip()
        result.append((key, op, value))
    return result


@dataclass
class EventCondition:
    """A condition that matches a log event by name and payload field constraints.

    Each constraint is a ``(key, op, value)`` tuple where *op* is one of
    ``=  !=  >  >=  <  <=``.
    """

    event: str                                          # e.g. "STATE_CHANGE"
    constraints: list[tuple[str, str, str]] = field(default_factory=list)

    def matches(self, entry: LogEntry) -> bool:
        """Return True if *entry* satisfies this condition."""
        if entry.event != self.event:
            return False
        payload = entry.payload if isinstance(entry.payload, dict) else {}
        for key, op, expected in self.constraints:
            actual = payload.get(key)
            if actual is None:
                return False
            if not _check_op(actual, op, expected):
                return False
        return True

    def __str__(self) -> str:
        parts = ", ".join(f"{k}{op}{v}" for k, op, v in self.constraints)
        return f"{self.event} {{{parts}}}" if parts else self.event


class DurationProfiler:
    """Measures durations between start/end event pairs across log files."""

    def __init__(
        self,
        log_dir,
        start_cond: EventCondition,
        end_cond: EventCondition,
        file_pattern: str | None = None,
        start_policy: str = "last",
        verbose: bool = False,
    ):
        self.log_dir = Path(log_dir)
        self.start_cond = start_cond
        self.end_cond = end_cond
        self.file_pattern = file_pattern or "*.log"
        self.start_policy = start_policy  # "first" or "last"
        self.verbose = verbose

        # Collected results
        self.records: list[DurationRecord] = []
        # Per-file results for detailed reporting
        self.per_file: dict[str, list[DurationRecord]] = {}
        self._total_files: int = 0

    # ------------------------------------------------------------------
    # File discovery
    # ------------------------------------------------------------------

    def _find_files(self) -> list[Path]:
        """Find log files matching the file pattern."""
        files = sorted(self.log_dir.glob(self.file_pattern))
        # Filter to regular files only
        return [f for f in files if f.is_file()]

    # ------------------------------------------------------------------
    # Per-file profiling
    # ------------------------------------------------------------------

    def _profile_file(self, path: Path) -> list[DurationRecord]:
        """Parse one log file and return duration records."""
        # Collect events for both conditions (they may share the same event name)
        target_events = {self.start_cond.event}
        if self.end_cond.event != self.start_cond.event:
            target_events.add(self.end_cond.event)

        try:
            entries = parse_file(path, events=target_events)
        except Exception as e:
            if self.verbose:
                print(f"  Error parsing {path.name}: {e}", file=sys.stderr)
            return []

        records = []
        pending_start: LogEntry | None = None

        for entry in entries:
            if self.start_cond.matches(entry):
                if self.start_policy == "first" and pending_start is not None:
                    pass  # keep the first start, ignore subsequent
                else:
                    pending_start = entry  # "last": overwrite with latest
            elif self.end_cond.matches(entry) and pending_start is not None:
                payload_start = (
                    pending_start.payload
                    if isinstance(pending_start.payload, dict)
                    else {}
                )
                payload_end = (
                    entry.payload if isinstance(entry.payload, dict) else {}
                )
                records.append(
                    DurationRecord(
                        start_time=pending_start.time,
                        end_time=entry.time,
                        duration=entry.time - pending_start.time,
                        source_file=path.name,
                        start_payload=payload_start,
                        end_payload=payload_end,
                    )
                )
                pending_start = None

        return records

    # ------------------------------------------------------------------
    # Orchestration
    # ------------------------------------------------------------------

    def profile_all(self):
        """Profile all matching files and collect results."""
        files = self._find_files()
        self._total_files = len(files)

        if self.verbose:
            print(f"  Found {len(files)} files matching '{self.file_pattern}'",
                  file=sys.stderr)

        if not files:
            return

        if len(files) > 1 and not getattr(self, "_sequential", False):
            self._profile_parallel(files)
        else:
            for f in files:
                recs = self._profile_file(f)
                if recs:
                    self.records.extend(recs)
                    self.per_file[f.name] = recs

    def _profile_parallel(self, files: list[Path], max_workers: int = 4):
        """Profile files in parallel."""
        workers = min(max_workers, len(files))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(self._profile_file, files))

        for f, recs in zip(files, results):
            if recs:
                self.records.extend(recs)
                self.per_file[f.name] = recs

    # ------------------------------------------------------------------
    # Statistics
    # ------------------------------------------------------------------

    def get_stats(self) -> dict:
        """Return aggregate statistics over all collected durations."""
        if not self.records:
            return {
                "count": 0,
                "total_files": self._total_files,
                "files_with_matches": 0,
            }

        durations = [r.duration for r in self.records]
        durations_sorted = sorted(durations)
        n = len(durations_sorted)

        return {
            "count": n,
            "total_files": self._total_files,
            "files_with_matches": len(self.per_file),
            "min": durations_sorted[0],
            "max": durations_sorted[-1],
            "avg": sum(durations) / n,
            "median": durations_sorted[n // 2],
            "total": sum(durations),
        }

    def get_per_file_stats(self) -> list[dict]:
        """Return per-file statistics sorted by filename."""
        results = []
        for fname in sorted(self.per_file):
            recs = self.per_file[fname]
            durations = [r.duration for r in recs]
            results.append({
                "file": fname,
                "count": len(durations),
                "min": min(durations),
                "max": max(durations),
                "avg": sum(durations) / len(durations),
                "total": sum(durations),
            })
        return results
