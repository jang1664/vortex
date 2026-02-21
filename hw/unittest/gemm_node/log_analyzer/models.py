"""Data models for FSIM Log Analyzer."""

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class FileStatus:
    """Tracks the status of a log file."""

    path: Path
    size: int
    mtime: float
    last_check: float
    changed_since_last_check: bool = False


@dataclass
class PacketEvent:
    """Represents a single packet event in the log."""

    timestamp: int
    uuid: int
    event_type: str  # "TX" or "RX"
    direction: str  # "LOCAL", "NORTH", "EAST", "SOUTH", "WEST"
    node: str  # node identifier from filename
    fifo_id: int
    cmd: str  # command type
    addr: int
    word: int
    raw_line: str


@dataclass
class PacketTrace:
    """Tracks the complete trace of a packet by UUID."""

    uuid: int
    events: list[PacketEvent] = field(default_factory=list)
    issued_time: Optional[int] = None
    issued_node: Optional[str] = None
    delivered_time: Optional[int] = None
    delivered_node: Optional[str] = None

    @property
    def is_delivered(self) -> bool:
        """Check if packet reached its destination (TX LOCAL = router sends to local node)."""
        return any(
            e.event_type == "TX" and e.direction == "LOCAL" for e in self.events
        )

    @property
    def latency(self) -> Optional[int]:
        """Calculate packet latency (delivered - issued). Always >= 0 if correct."""
        if self.issued_time is not None and self.delivered_time is not None:
            return self.delivered_time - self.issued_time
        return None

    @property
    def hop_count(self) -> int:
        """Count number of network hops (TX to non-LOCAL directions)."""
        return len([e for e in self.events
                    if e.event_type == "TX" and e.direction != "LOCAL"])

    def get_path(self) -> list[str]:
        """Get the path taken by the packet."""
        return [e.node for e in sorted(self.events, key=lambda x: x.timestamp)]


@dataclass
class SyncEvent:
    """Represents a synchronization event (flag/standby)."""
    timestamp: int
    node: str
    node_type: str  # "inode" or "imce"
    event_type: str  # "EX_STALL_START", "EXECUTE", "SEND_SUCCESS", etc.
    payload: dict  # parsed structured payload
    raw_line: str
    source_file: str = ""  # which log file this came from


@dataclass
class StallInfo:
    """Represents an active stall at end of simulation."""
    node: str           # "imce_3_2" or "inode_0_0"
    node_type: str      # "inode" or "imce"
    row: int
    col: int
    stall_type: str     # "EX_STALL", "WB_STALL", "IF_STALL"
    reason: str         # "RECV_FIFO", "STANDBY", etc.
    start_time: int     # timestamp of STALL_START
    payload: dict       # full payload from the START event
    source_file: str    # which log file


@dataclass
class DurationRecord:
    """A measured duration between a start event and an end event."""
    start_time: int     # timestamp of start event
    end_time: int       # timestamp of end event
    duration: int       # end_time - start_time
    source_file: str    # which log file
    start_payload: dict # full payload of the start event
    end_payload: dict   # full payload of the end event
