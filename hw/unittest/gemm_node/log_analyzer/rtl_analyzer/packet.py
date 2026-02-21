"""Packet trace analysis from FSIM log files."""

import re
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

from log_analyzer.log_format import parse_file, LogEntry
from log_analyzer.models import PacketEvent, PacketTrace


# Events relevant for packet analysis
PACKET_EVENTS = {"RX_TRANSFER", "TX_TRANSFER"}


class PacketAnalyzer:
    """Analyzes packet traces from FSIM log files."""

    def __init__(self, log_dir: Path, verbose: bool = False):
        """
        Initialize packet analyzer.

        Args:
            log_dir: Directory containing log files
            verbose: Print detailed parsing information
        """
        self.log_dir = Path(log_dir)
        self.verbose = verbose
        self.packets: dict[int, PacketTrace] = {}
        self.node_stats: dict[str, dict] = defaultdict(
            lambda: {"rx_count": 0, "tx_count": 0, "packets": set()}
        )

    def _extract_node_from_filename(self, filename: str) -> str:
        """Extract node identifier from log filename."""
        match = re.search(
            r"(core_row\[\d+\]\.core_col\[\d+\]\.(inode|imce_node))", filename
        )
        if match:
            return match.group(1)
        return filename

    def _process_entry(self, entry: LogEntry, node: str):
        """Process a single LogEntry into packet data structures.

        Extracts packet events and updates self.packets / self.node_stats.
        NOT thread-safe — must be called from a single thread.
        """
        p = entry.payload if isinstance(entry.payload, dict) else {}

        # Determine event type from the structured event name
        if entry.event == "RX_TRANSFER":
            event_type = "RX"
        elif entry.event == "TX_TRANSFER":
            event_type = "TX"
        else:
            return

        uuid = p.get("uuid", 0)
        if isinstance(uuid, str):
            try:
                uuid = int(uuid)
            except ValueError:
                uuid = 0

        event = PacketEvent(
            timestamp=entry.time,
            uuid=uuid,
            event_type=event_type,
            direction=str(p.get("dir", "")),
            node=node,
            fifo_id=int(p.get("fifo_id", 0)),
            cmd=str(p.get("cmd", "")),
            addr=int(p.get("addr", 0)),
            word=int(p.get("word", 0)),
            raw_line=entry.raw,
        )

        # Add event to packet trace
        if uuid not in self.packets:
            self.packets[uuid] = PacketTrace(uuid=uuid)

        trace = self.packets[uuid]
        trace.events.append(event)

        # Track issued time and node:
        #   RX LOCAL = router receives from local node = packet INJECTION
        if (
            event.event_type == "RX" and event.direction == "LOCAL"
            and trace.issued_time is None
        ):
            trace.issued_time = event.timestamp
            trace.issued_node = node

        # Track delivered time and node:
        #   TX LOCAL = router sends to local node = packet DELIVERY
        if (
            event.event_type == "TX" and event.direction == "LOCAL"
        ):
            if (
                trace.delivered_time is None
                or event.timestamp > trace.delivered_time
            ):
                trace.delivered_time = event.timestamp
                trace.delivered_node = node

        # Update node statistics
        if event.event_type == "RX":
            self.node_stats[node]["rx_count"] += 1
        else:
            self.node_stats[node]["tx_count"] += 1
        self.node_stats[node]["packets"].add(uuid)

    def parse_log_file(self, log_file: Path):
        """Parse a single log file and extract packet events."""
        if not log_file.exists():
            return

        node = self._extract_node_from_filename(log_file.name)

        if self.verbose:
            print(f"Parsing {log_file.name}...", file=sys.stderr)

        try:
            entries = parse_file(log_file, events=PACKET_EVENTS)
        except Exception as e:
            print(f"Error parsing {log_file.name}: {e}", file=sys.stderr)
            return

        for entry in entries:
            self._process_entry(entry, node)

    def _parse_all_logs_parallel(self, log_files: list[Path], max_workers: int = 4):
        """Parse log files in parallel using grep + thread pool.

        Phase 1 (parallel): Each file gets its own grep + parse in a thread.
        Phase 2 (sequential): Results accumulated into self.packets / self.node_stats.
        """
        try:
            from log_analyzer.fast_search import fast_parse_file
        except ImportError:
            return False

        # Build list of (file, node) pairs
        file_node_pairs = [
            (lf, self._extract_node_from_filename(lf.name))
            for lf in log_files if lf.exists()
        ]
        if not file_node_pairs:
            return True

        def _parse_one(pair: tuple[Path, str]) -> tuple[str, list[LogEntry]]:
            lf, node = pair
            try:
                entries = fast_parse_file(lf, PACKET_EVENTS)
            except Exception as e:
                print(f"Error parsing {lf.name}: {e}", file=sys.stderr)
                entries = []
            return node, entries

        workers = min(max_workers, len(file_node_pairs))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(_parse_one, file_node_pairs))

        # Sequential accumulation (not thread-safe structures)
        for node, entries in results:
            for entry in entries:
                self._process_entry(entry, node)

        return True

    def parse_all_logs(self):
        """Parse all log files in the log directory."""
        if not self.log_dir.exists():
            raise FileNotFoundError(f"Log directory not found: {self.log_dir}")

        log_files = list(self.log_dir.glob("*.log"))

        if self.verbose:
            print(f"Found {len(log_files)} log files", file=sys.stderr)

        # Try parallel path for multiple files
        if len(log_files) > 1 and not getattr(self, '_sequential', False):
            if self._parse_all_logs_parallel(log_files):
                if self.verbose:
                    print(
                        f"Parsed {len(self.packets)} unique packets (parallel)",
                        file=sys.stderr,
                    )
                return

        # Sequential fallback
        for log_file in log_files:
            self.parse_log_file(log_file)

        if self.verbose:
            print(
                f"Parsed {len(self.packets)} unique packets",
                file=sys.stderr,
            )

    def sanity_check(self) -> dict:
        """Run sanity checks on parsed packet data.

        Checks:
        1. UUID=0 default (no UUID field in logs → non-DEBUG build)
        2. Duplicate RX LOCAL per UUID (injection should be unique)
        3. Negative latency (should never happen after fix)

        Returns dict with:
            ok: bool - True if all checks pass
            warnings: list[str] - warning messages
            errors: list[str] - error messages
            duplicate_rx_local: dict[int, list] - UUID → list of (node, timestamp) for duplicates
        """
        warnings: list[str] = []
        errors: list[str] = []
        duplicate_rx_local: dict[int, list] = {}

        # Check 1: UUID=0 means no UUID in log (non-DEBUG build)
        if 0 in self.packets and len(self.packets[0].events) > 1:
            errors.append(
                f"UUID=0 has {len(self.packets[0].events)} events. "
                f"Logs likely built without DEBUG flag — UUID field is missing. "
                f"Packet tracing requires DEBUG-enabled FSIM logs."
            )

        # Check 2: Each UUID should have at most 1 RX LOCAL (injection point)
        for uuid, trace in self.packets.items():
            rx_locals = [
                (e.node, e.timestamp) for e in trace.events
                if e.event_type == "RX" and e.direction == "LOCAL"
            ]
            if len(rx_locals) > 1:
                duplicate_rx_local[uuid] = rx_locals
                errors.append(
                    f"UUID {uuid}: {len(rx_locals)} RX LOCAL events "
                    f"(expected 1). Nodes: {[n for n, _ in rx_locals]}"
                )

        # Check 3: Negative latency
        neg_latency_count = 0
        for trace in self.packets.values():
            lat = trace.latency
            if lat is not None and lat < 0:
                neg_latency_count += 1
        if neg_latency_count > 0:
            errors.append(
                f"{neg_latency_count} packets have negative latency. "
                f"This indicates issued/delivered time tracking is wrong."
            )

        # Check 4: Packets with events but no issued_time
        no_issued = sum(
            1 for t in self.packets.values()
            if t.issued_time is None and len(t.events) > 0
        )
        if no_issued > 0:
            warnings.append(
                f"{no_issued} packets have events but no injection point "
                f"(no RX LOCAL found)."
            )

        ok = len(errors) == 0
        return {
            "ok": ok,
            "warnings": warnings,
            "errors": errors,
            "duplicate_rx_local": duplicate_rx_local,
        }

    def get_undelivered_packets(self) -> list[PacketTrace]:
        """Get packets that were issued but not delivered to destination."""
        return [
            trace
            for trace in self.packets.values()
            if trace.issued_time is not None and not trace.is_delivered
        ]

    def get_delivered_packets(self) -> list[PacketTrace]:
        """Get packets that were successfully delivered."""
        return [trace for trace in self.packets.values() if trace.is_delivered]

    def get_packet_by_uuid(self, uuid: int) -> Optional[PacketTrace]:
        """Get packet trace by UUID."""
        return self.packets.get(uuid)

    def get_latency_stats(self) -> dict:
        """Calculate latency statistics for delivered packets."""
        latencies = [
            trace.latency
            for trace in self.packets.values()
            if trace.latency is not None
        ]

        if not latencies:
            return {
                "count": 0,
                "min": 0,
                "max": 0,
                "avg": 0,
                "median": 0,
            }

        latencies.sort()
        return {
            "count": len(latencies),
            "min": latencies[0],
            "max": latencies[-1],
            "avg": sum(latencies) / len(latencies),
            "median": latencies[len(latencies) // 2],
        }

    def get_node_traffic_stats(self) -> dict[str, dict]:
        """Get traffic statistics by node."""
        stats = {}
        for node, data in self.node_stats.items():
            stats[node] = {
                "rx_count": data["rx_count"],
                "tx_count": data["tx_count"],
                "unique_packets": len(data["packets"]),
                "total_traffic": data["rx_count"] + data["tx_count"],
            }
        return stats

    def get_cmd_type_stats(self) -> dict[str, int]:
        """Get statistics by command type."""
        cmd_counts = defaultdict(int)
        for trace in self.packets.values():
            for event in trace.events:
                if event.cmd:
                    cmd_counts[event.cmd] += 1
        return dict(cmd_counts)

    def get_hotspots(
        self, top_n: int = 5, metric: str = "total_traffic"
    ) -> list[tuple[str, dict]]:
        """
        Get top N nodes with highest traffic.

        Args:
            top_n: Number of top nodes to return
            metric: Metric to sort by ('total_traffic', 'rx_count', 'tx_count', 'unique_packets')
        """
        stats = self.get_node_traffic_stats()
        sorted_nodes = sorted(
            stats.items(), key=lambda x: x[1].get(metric, 0), reverse=True
        )
        return sorted_nodes[:top_n]
