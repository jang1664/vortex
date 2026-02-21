"""Synchronization trace analysis between nodes."""

import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

from log_analyzer.log_format import parse_file, LogEntry
from log_analyzer.models import SyncEvent


# Events relevant for sync trace analysis
SYNC_EVENTS = {
    # Stall events (from hazard_control / hazard_detector)
    "EX_STALL_START", "EX_STALL_END",
    "WB_STALL_START", "WB_STALL_END",
    # Execute events (from ctrl_pipeline)
    "EXECUTE", "BUBBLE", "STALL_START",
    # Handshake events (from imce_ctrl)
    "SEND_SUCCESS", "RECV_SUCCESS", "STEP_SUCCESS",
    "SEND_STALL_START", "SEND_STALL_END",
    "RECV_STALL_START", "RECV_STALL_END",
    "STEP_STALL_START", "STEP_STALL_END",
    # WB events (from WB_stage)
    "SEND", "IMEM_WRITE", "IMCE_COMPUTE", "POLICY_UPDATE",
    # EX stage events
    "EX_START", "EX_END",
    # ID_EX events
    "ID_EX",
    # Bug detection
    "BUG_DETECT",
}


class SyncTraceAnalyzer:
    """Analyzes synchronization events (flag/standby) between nodes."""

    def __init__(self, log_dir: Path, nodes: list[str], verbose: bool = False,
                 debug: bool = False):
        """
        Initialize sync trace analyzer.

        Args:
            log_dir: Directory containing fsim log files
            nodes: List of node identifiers (e.g., ["inode_0_0", "imce_3_4"])
            verbose: Print detailed parsing information
            debug: Enable expensive diagnostics (e.g. counting unparsed lines)
        """
        self.log_dir = Path(log_dir)
        self.nodes = [n.lower().replace(".", "_") for n in nodes]
        self.verbose = verbose
        self.debug = debug
        self.events: list[SyncEvent] = []
        self._unparsed_counts: dict[str, int] = {}

    def _find_log_files_for_node(self, node: str) -> list[tuple[Path, str]]:
        """Find relevant log files for a node.

        Returns list of (path, node_type) tuples.
        """
        files = []
        node_lower = node.lower()

        # Determine node type
        if "inode" in node_lower:
            node_type = "inode"
            match = re.search(r'inode[_.]?(\d+)[_.]?(\d+)', node_lower)
        else:
            node_type = "imce"
            match = re.search(r'imce[_.]?(\d+)[_.]?(\d+)', node_lower)

        if not match:
            return files

        row, col = match.groups()

        # Find all matching log files for this node
        for log_file in self.log_dir.glob("*.log"):
            fname = log_file.name.lower()
            if f"core_row[{row}].core_col[{col}]" in fname.lower():
                if node_type == "inode":
                    # Include inode-relevant log files
                    if any(k in fname for k in ("hazard_control", "wb_stage", "ex_stage",
                                                 "id_ex_pipe", "mem_stage", "ctrl_pipeline")):
                        if "send_fifo" not in fname and "recv_fifo" not in fname:
                            files.append((log_file, node_type))
                else:  # imce
                    if any(k in fname for k in ("hazard_detector", "u_imce_ctrl",
                                                 "ctrl_pipeline")):
                        if "hazard" not in fname or "hazard_detector" in fname:
                            files.append((log_file, node_type))

        return files

    def _process_entries(self, entries: list[LogEntry], node: str, node_type: str,
                         source_file: str):
        """Accumulate parsed entries into self.events. NOT thread-safe."""
        for entry in entries:
            self.events.append(SyncEvent(
                timestamp=entry.time,
                node=node,
                node_type=node_type,
                event_type=entry.event,
                payload=entry.payload if isinstance(entry.payload, dict) else {},
                raw_line=entry.raw,
                source_file=source_file,
            ))

    def _parse_log_file(self, log_file: Path, node: str, node_type: str):
        """Parse a log file using the structured format parser."""
        if not log_file.exists():
            return

        if self.verbose:
            print(f"  Parsing {log_file.name}...", file=sys.stderr)

        try:
            entries = parse_file(log_file, events=SYNC_EVENTS)
        except Exception as e:
            if self.verbose:
                print(f"  Error parsing {log_file.name}: {e}", file=sys.stderr)
            return

        self._process_entries(entries, node, node_type, log_file.name)

        # Count unparsed lines only when verbose+debug (expensive: re-reads file)
        if self.verbose and self.debug:
            unparsed = self._count_unparsed_lines(log_file)
            if unparsed > 0:
                self._unparsed_counts[log_file.name] = unparsed

    def _count_unparsed_lines(self, log_file: Path) -> int:
        """Count lines that couldn't be parsed by the structured parser.

        This re-reads the entire file and is expensive — only called
        when both verbose and debug are enabled.
        """
        from log_analyzer.log_format import parse_line as _parse_line

        count = 0
        try:
            with open(log_file) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    if _parse_line(line) is None:
                        count += 1
        except Exception:
            pass
        return count

    def _parse_all_parallel(self, all_files: list[tuple[Path, str, str]],
                            max_workers: int = 4) -> bool:
        """Parse all files in parallel using grep + thread pool.

        Args:
            all_files: List of (log_file, node, node_type) tuples.
            max_workers: Maximum concurrent workers.

        Returns:
            True if parallel path was used, False if it should fall back.
        """
        try:
            from log_analyzer.fast_search import fast_parse_file
        except ImportError:
            return False

        def _parse_one(item: tuple[Path, str, str]) -> tuple[str, str, str, list[LogEntry]]:
            lf, node, node_type = item
            try:
                entries = fast_parse_file(lf, SYNC_EVENTS)
            except Exception as e:
                if self.verbose:
                    print(f"  Error parsing {lf.name}: {e}", file=sys.stderr)
                entries = []
            return node, node_type, lf.name, entries

        workers = min(max_workers, len(all_files))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(_parse_one, all_files))

        # Sequential accumulation
        for node, node_type, fname, entries in results:
            self._process_entries(entries, node, node_type, fname)

        return True

    def parse_all(self):
        """Parse all relevant log files for the specified nodes."""
        # Collect all (file, node, node_type) tuples
        all_files: list[tuple[Path, str, str]] = []
        for node in self.nodes:
            files = self._find_log_files_for_node(node)
            if self.verbose:
                print(f"Found {len(files)} log files for {node}", file=sys.stderr)
            for log_file, node_type in files:
                all_files.append((log_file, node, node_type))

        # Try parallel path for multiple files
        if len(all_files) > 1 and not getattr(self, '_sequential', False):
            if self._parse_all_parallel(all_files):
                self.events.sort(key=lambda e: e.timestamp)
                return

        # Sequential fallback
        for log_file, node, node_type in all_files:
            self._parse_log_file(log_file, node, node_type)

        # Sort events by timestamp
        self.events.sort(key=lambda e: e.timestamp)

        if self.verbose and self._unparsed_counts:
            print(f"  Unparsed line counts:", file=sys.stderr)
            for fname, count in self._unparsed_counts.items():
                print(f"    {fname}: {count} lines", file=sys.stderr)

    def get_events_in_range(self, start_time: Optional[int] = None, end_time: Optional[int] = None) -> list[SyncEvent]:
        """Get events within a time range."""
        result = self.events
        if start_time is not None:
            result = [e for e in result if e.timestamp >= start_time]
        if end_time is not None:
            result = [e for e in result if e.timestamp <= end_time]
        return result

    def filter_by_event_type(self, event_types: list[str]) -> list[SyncEvent]:
        """Filter events by type."""
        return [e for e in self.events if e.event_type in event_types]
