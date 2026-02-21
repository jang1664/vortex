"""Stall analysis for finding nodes stuck at end of simulation.

Scans all inode/imce hazard log files for STALL_START/STALL_END pairs.
Any STALL_START without a matching STALL_END at EOF is reported as an
active stall — the node was still blocked when the simulation ended.
"""

import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

from log_analyzer.log_format import parse_file, LogEntry
from log_analyzer.models import StallInfo

# Events we need to track stall state
STALL_ANALYSIS_EVENTS = {
    "EX_STALL_START", "EX_STALL_END",
    "WB_STALL_START", "WB_STALL_END",
    "IF_STALL_START", "IF_STALL_END",
}

# Regex for extracting node coordinates from log filenames
# Matches: core_row_0_.core_col_3_.inode  or  core_row_2_.core_col_1_.imce_node
_NODE_RE = re.compile(
    r"core_row_(\d+)_\.core_col_(\d+)_\.(inode|imce_node)"
)

# Hazard log file identifiers per node type
_HAZARD_FILE_KEYWORDS = {
    "inode": "hazard_control",
    "imce": "hazard_detector",
}


class StallAnalyzer:
    """Finds nodes that are still stalled at end of simulation."""

    def __init__(self, log_dir, verbose: bool = False):
        self.log_dir = Path(log_dir)
        self.verbose = verbose
        self.stalls: list[StallInfo] = []
        self._node_last_times: dict[str, int] = {}
        self._total_nodes: int = 0

    # ------------------------------------------------------------------
    # Node discovery
    # ------------------------------------------------------------------

    def _discover_nodes(self) -> list[tuple[str, str, int, int, Path]]:
        """Auto-discover all inode/imce nodes from log filenames.

        Returns:
            List of (node_id, node_type, row, col, hazard_log_path).
        """
        # First, find all unique (row, col, node_type) from filenames
        nodes: dict[tuple[int, int, str], None] = {}
        for log_file in self.log_dir.glob("*.log"):
            m = _NODE_RE.search(log_file.name)
            if m:
                row, col = int(m.group(1)), int(m.group(2))
                raw_type = m.group(3)
                node_type = "imce" if raw_type == "imce_node" else "inode"
                nodes[(row, col, node_type)] = None

        # Now find the hazard log file for each node
        result = []
        for (row, col, node_type) in sorted(nodes):
            keyword = _HAZARD_FILE_KEYWORDS[node_type]
            raw_type = "imce_node" if node_type == "imce" else "inode"
            # Build the expected filename pattern (matches: core_row_0_.core_col_1_.imce_node)
            prefix = f"core_row_{row}_.core_col_{col}_.{raw_type}"
            hazard_path = None
            for log_file in self.log_dir.glob("*.log"):
                if prefix in log_file.name and keyword in log_file.name:
                    hazard_path = log_file
                    break

            if hazard_path is None:
                if self.verbose:
                    print(f"  Warning: no {keyword} log for {node_type}({row},{col})",
                          file=sys.stderr)
                continue

            node_id = f"{node_type}_{row}_{col}"
            result.append((node_id, node_type, row, col, hazard_path))

        return result

    # ------------------------------------------------------------------
    # Per-node parsing
    # ------------------------------------------------------------------

    def _parse_node(self, path: Path, node_id: str, node_type: str,
                    row: int, col: int) -> list[StallInfo]:
        """Parse a single hazard log and return active stalls at EOF."""
        try:
            entries = parse_file(path, events=STALL_ANALYSIS_EVENTS)
        except Exception as e:
            if self.verbose:
                print(f"  Error parsing {path.name}: {e}", file=sys.stderr)
            return []

        # Track last event time for the node
        if entries:
            self._node_last_times[node_id] = entries[-1].time

        # Track open stalls: (stall_prefix, reason) -> LogEntry
        open_stalls: dict[tuple[str, str], LogEntry] = {}

        for entry in entries:
            event = entry.event
            payload = entry.payload if isinstance(entry.payload, dict) else {}
            reason = str(payload.get("reason", "UNKNOWN"))

            if event.endswith("_STALL_START"):
                # e.g. "EX_STALL_START" -> prefix "EX_STALL"
                prefix = event.rsplit("_", 1)[0]  # "EX_STALL"
                open_stalls[(prefix, reason)] = entry

            elif event.endswith("_STALL_END"):
                prefix = event.rsplit("_", 1)[0]  # "EX_STALL"
                # Close the matching stall
                open_stalls.pop((prefix, reason), None)

        # Filter out propagated stalls — these are derived from another
        # pipeline stage's stall and are not root causes.
        _PROPAGATED_REASONS = {"PROPAGATED_FROM_MEM"}
        open_stalls = {
            k: v for k, v in open_stalls.items()
            if k[1] not in _PROPAGATED_REASONS
        }

        # Convert remaining open stalls to StallInfo
        active = []
        for (stall_type, reason), entry in open_stalls.items():
            payload = entry.payload if isinstance(entry.payload, dict) else {}
            active.append(StallInfo(
                node=node_id,
                node_type=node_type,
                row=row,
                col=col,
                stall_type=stall_type,
                reason=reason,
                start_time=entry.time,
                payload=payload,
                source_file=path.name,
            ))

        return active

    # ------------------------------------------------------------------
    # Parallel / sequential orchestration
    # ------------------------------------------------------------------

    def _parse_all_parallel(
        self, discovered: list[tuple[str, str, int, int, Path]], max_workers: int = 4
    ):
        """Parse all nodes in parallel using thread pool."""
        def _parse_one(item):
            node_id, node_type, row, col, path = item
            return self._parse_node(path, node_id, node_type, row, col)

        workers = min(max_workers, len(discovered))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(_parse_one, discovered))

        for stalls in results:
            self.stalls.extend(stalls)

    def parse_all(self):
        """Discover all nodes and find active stalls."""
        discovered = self._discover_nodes()
        self._total_nodes = len(discovered)

        if self.verbose:
            print(f"  Discovered {len(discovered)} nodes", file=sys.stderr)

        if not discovered:
            return

        if len(discovered) > 1 and not getattr(self, '_sequential', False):
            self._parse_all_parallel(discovered)
        else:
            for node_id, node_type, row, col, path in discovered:
                stalls = self._parse_node(path, node_id, node_type, row, col)
                self.stalls.extend(stalls)

        # Sort by start_time
        self.stalls.sort(key=lambda s: s.start_time)

    # ------------------------------------------------------------------
    # Summary / reporting helpers
    # ------------------------------------------------------------------

    def get_stall_summary(self) -> dict:
        """Return a summary dict with counts by reason and node_type."""
        by_reason: dict[str, int] = {}
        by_node_type: dict[str, int] = {}
        stalled_nodes: set[str] = set()

        for s in self.stalls:
            by_reason[s.reason] = by_reason.get(s.reason, 0) + 1
            by_node_type[s.node_type] = by_node_type.get(s.node_type, 0) + 1
            stalled_nodes.add(s.node)

        return {
            "total_nodes": self._total_nodes,
            "stalled_nodes": len(stalled_nodes),
            "total_stalls": len(self.stalls),
            "by_reason": dict(sorted(by_reason.items(), key=lambda x: -x[1])),
            "by_node_type": by_node_type,
        }
