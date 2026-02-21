"""Fast grep-based search and parallel file parsing for FSIM log files.

Uses rg/grep (C-native, memory-mapped I/O) to pre-filter matching lines
before feeding them through the Python parser, providing orders-of-magnitude
speedup for large log files where only a small fraction of lines match.
"""

import os
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Generator, Optional, Union

from .log_format import LogEntry, parse_line

# Minimum file size (bytes) to bother with grep subprocess.
# Below this, Python-native reading is faster due to subprocess startup overhead.
_SMALL_FILE_THRESHOLD = 1 * 1024 * 1024  # 1 MB

# Cached search tool detection
_search_tool: Optional[tuple[str, list[str]]] = None
_search_tool_checked = False


def _get_search_tool() -> Optional[tuple[str, list[str]]]:
    """Detect available grep tool.  Returns (cmd, base_args) or None.

    Prefers ``rg`` (ripgrep) for speed, falls back to ``grep -E``.
    Result is cached at module level after first call.
    """
    global _search_tool, _search_tool_checked
    if _search_tool_checked:
        return _search_tool

    rg = shutil.which("rg")
    if rg:
        _search_tool = (rg, ["-N", "--no-ignore", "--no-heading", "--color", "never"])
        _search_tool_checked = True
        return _search_tool

    grep = shutil.which("grep")
    if grep:
        _search_tool = (grep, ["-E"])
        _search_tool_checked = True
        return _search_tool

    _search_tool = None
    _search_tool_checked = True
    return None


def _build_event_pattern(events: set[str]) -> str:
    r"""Build a regex pattern that matches structured log lines with given events.

    The log format is::

        [<time>] | <EVENT> | <payload>
        [<time>] | <EVENT>

    The pattern anchors on ``^\[`` and matches the event field between
    ``| `` delimiters to avoid false positives from event names appearing
    inside payload data.

    Returns:
        A regex string suitable for ``rg`` or ``grep -E``.
    """
    # Escape any regex-special characters in event names (unlikely but safe)
    escaped = [re.escape(e) for e in sorted(events)]
    alternatives = "|".join(escaped)
    # Match both RTL and pysim formats:
    #   RTL:   [<time>] | <EVENT> | ...   OR  [<time>] | <EVENT>$
    #   Pysim: ...:<time>] | <EVENT> | ... (prefix before '[')
    return r"\[.*\] \| (" + alternatives + r")( \||$)"


def _python_grep_fallback(
    path: Union[str, Path], events: set[str]
) -> Generator[str, None, None]:
    """Pure-Python fallback when no grep tool is available.

    Performs a fast string-level pre-filter before yielding lines.
    """
    # Pre-build set of " | EVENT |" and " | EVENT\n"/EOL patterns for fast check
    event_markers = {f" | {e} |" for e in events}
    event_markers_eol = {f" | {e}" for e in events}

    with open(path) as f:
        for line in f:
            # Quick reject: line must contain '[' somewhere (RTL or pysim)
            if "[" not in line:
                continue
            # Quick check: does line contain any event marker?
            for marker in event_markers:
                if marker in line:
                    yield line
                    break
            else:
                # Check end-of-line variant (no payload)
                stripped = line.rstrip("\n")
                for marker in event_markers_eol:
                    if stripped.endswith(marker):
                        yield line
                        break


def grep_file(
    path: Union[str, Path], events: set[str]
) -> Generator[str, None, None]:
    """Use rg/grep to extract matching lines from a log file.

    Streams results line-by-line from the subprocess stdout.
    Falls back to :func:`_python_grep_fallback` if no grep tool is available
    or if the file is too small to benefit from subprocess overhead.

    Args:
        path: Path to the log file.
        events: Set of event names to search for.

    Yields:
        Matching lines (with trailing newline stripped).
    """
    path = Path(path)

    # Skip grep for small files — subprocess startup dominates
    try:
        file_size = path.stat().st_size
    except OSError:
        return
    if file_size < _SMALL_FILE_THRESHOLD:
        yield from _python_grep_fallback(path, events)
        return

    tool = _get_search_tool()
    if tool is None:
        yield from _python_grep_fallback(path, events)
        return

    cmd, base_args = tool
    pattern = _build_event_pattern(events)

    try:
        proc = subprocess.Popen(
            [cmd, *base_args, pattern, str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,  # line-buffered
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            yield line.rstrip("\n")
        proc.wait()
    except (OSError, subprocess.SubprocessError):
        # If subprocess fails, fall back to Python
        yield from _python_grep_fallback(path, events)


def fast_parse_file(
    path: Union[str, Path],
    events: set[str],
) -> list[LogEntry]:
    """Parse a log file using grep pre-filtering + Python parsing.

    Drop-in replacement for ``parse_file()`` when *events* is specified.

    Phase 1: ``grep_file()`` extracts only lines matching target events.
    Phase 2: ``parse_line()`` parses the matched lines into LogEntry objects.

    Args:
        path: Path to the log file.
        events: Set of event names to filter for.

    Returns:
        List of ``LogEntry`` objects, in file order.
    """
    entries: list[LogEntry] = []
    for line in grep_file(path, events):
        entry = parse_line(line)
        if entry is None:
            continue
        # Double-check event filter (grep pattern may have edge-case matches)
        if entry.event not in events:
            continue
        entries.append(entry)
    return entries


def fast_parse_files(
    paths: list[Union[str, Path]],
    events: set[str],
    max_workers: int = 4,
) -> list[list[LogEntry]]:
    """Parse multiple log files in parallel using grep + thread pool.

    Each file gets its own grep subprocess running in a separate thread.
    Results are returned in the same order as the input *paths*.

    Args:
        paths: List of paths to log files.
        events: Set of event names to filter for.
        max_workers: Maximum number of concurrent workers.

    Returns:
        List of lists, one per input path, each containing ``LogEntry`` objects.
    """
    if not paths:
        return []

    if len(paths) == 1:
        return [fast_parse_file(paths[0], events)]

    def _parse_one(p: Union[str, Path]) -> list[LogEntry]:
        return fast_parse_file(p, events)

    with ThreadPoolExecutor(max_workers=min(max_workers, len(paths))) as pool:
        results = list(pool.map(_parse_one, paths))

    return results
