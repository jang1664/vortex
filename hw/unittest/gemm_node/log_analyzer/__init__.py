"""Log Analyzer - Shared infrastructure for parsing IMCFlow structured logs.

Supports both RTL (fsim) and Python simulator (pysim) log formats.
"""

from .log_format import LogEntry, ParseError, parse_payload, parse_line, parse_file
from .fast_search import fast_parse_file, fast_parse_files, grep_file
from .models import FileStatus, PacketEvent, PacketTrace, SyncEvent, StallInfo, DurationRecord
from .utils import parse_patterns, split_log_by_simulation

__all__ = [
    "LogEntry",
    "ParseError",
    "parse_payload",
    "parse_line",
    "parse_file",
    "fast_parse_file",
    "fast_parse_files",
    "grep_file",
    "FileStatus",
    "PacketEvent",
    "PacketTrace",
    "SyncEvent",
    "StallInfo",
    "DurationRecord",
    "parse_patterns",
    "split_log_by_simulation",
]
