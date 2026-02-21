"""
Structured Log Format Parser

Parses the IMCFlow structured log format:

    [<time>] | <EVENT> | {key=value, nested={a=1}, list=[x, y]}

The payload uses a relaxed JSON-like syntax (no quotes required):
    - Objects: {key=value, key2=value2}
    - Arrays:  [item1, item2, {nested=obj}]
    - Atoms:   integers (decimal/hex), identifiers, strings

Supports both RTL (fsim) and Python simulator (pysim) log formats:

    RTL:   [1234] | EXECUTE | {opcode=OP_ADD, rd=5, rs1=3}
    Pysim: 22:19:04:imcflow_sim.imcflow.imce:DEBUG   :[612] | IMCE_TRY_INST | {name=IMCE.2.1}

The pysim format has a ``timestamp:module:level:`` prefix before the
structured ``[step] | EVENT | {payload}`` core, which is automatically
stripped by :func:`parse_line`.

Usage:
    from log_analyzer.log_format import parse_line, parse_file, parse_payload

    # Parse a single line
    entry = parse_line("[1234] | EXECUTE | {opcode=OP_ADD, rd=5}")
    # LogEntry(time=1234, event='EXECUTE', payload={'opcode': 'OP_ADD', 'rd': 5})

    # Parse a file
    for entry in parse_file("path/to/log.log"):
        if entry.event == "EXECUTE":
            print(entry.payload["opcode"])

    # Parse just a payload string
    data = parse_payload("{requests=[{port=N}, {port=E}]}")
    # {'requests': [{'port': 'N'}, {'port': 'E'}]}
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Union

# Type alias for parsed values
Value = Union[int, str, dict, list]


@dataclass
class LogEntry:
    """A single parsed log line."""

    time: int
    event: str
    payload: Value
    raw: str = ""


class ParseError(Exception):
    """Raised when a payload string cannot be parsed."""

    def __init__(self, msg: str, text: str, pos: int):
        context = text[max(0, pos - 20):pos + 20]
        super().__init__(f"{msg} at pos {pos}: ...{context}...")
        self.pos = pos


# ---------------------------------------------------------------------------
# Recursive descent parser for relaxed JSON
# ---------------------------------------------------------------------------

def _skip_ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in " \t":
        i += 1
    return i


def _parse_value(s: str, i: int) -> tuple[Value, int]:
    """Parse one value starting at position *i*."""
    i = _skip_ws(s, i)
    if i >= len(s):
        raise ParseError("unexpected end of input", s, i)
    ch = s[i]
    if ch == "{":
        return _parse_obj(s, i)
    if ch == "[":
        return _parse_arr(s, i)
    return _parse_atom(s, i)


def _parse_obj(s: str, i: int) -> tuple[dict, int]:
    """Parse {key=value, key=value, ...}."""
    assert s[i] == "{"
    i += 1
    obj: dict[str, Value] = {}
    while True:
        i = _skip_ws(s, i)
        if i >= len(s):
            raise ParseError("unterminated object", s, i)
        if s[i] == "}":
            return obj, i + 1

        # Key: read until '='
        j = i
        while j < len(s) and s[j] not in "=}":
            j += 1
        if j >= len(s) or s[j] != "=":
            raise ParseError("expected '=' in object", s, j)
        key = s[i:j].strip()

        # Value
        val, i = _parse_value(s, j + 1)
        obj[key] = val

        # Separator
        i = _skip_ws(s, i)
        if i < len(s) and s[i] == ",":
            i += 1


def _parse_arr(s: str, i: int) -> tuple[list, int]:
    """Parse [value, value, ...]."""
    assert s[i] == "["
    i += 1
    arr: list[Value] = []
    while True:
        i = _skip_ws(s, i)
        if i >= len(s):
            raise ParseError("unterminated array", s, i)
        if s[i] == "]":
            return arr, i + 1

        val, i = _parse_value(s, i)
        arr.append(val)

        i = _skip_ws(s, i)
        if i < len(s) and s[i] == ",":
            i += 1


def _parse_atom(s: str, i: int) -> tuple[Union[int, str], int]:
    """Parse an atomic value (integer or unquoted string)."""
    j = i
    while j < len(s) and s[j] not in ",}] \t\n":
        j += 1
    if j == i:
        raise ParseError("empty atom", s, i)
    raw = s[i:j]

    # Try integer (handles 0x hex, 0b binary, plain decimal)
    try:
        return int(raw, 0), j
    except ValueError:
        pass

    # Negative integer
    if raw.startswith("-"):
        try:
            return int(raw, 0), j
        except ValueError:
            pass

    return raw, j


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def parse_payload(text: str) -> Value:
    """Parse a relaxed-JSON payload string.

    Args:
        text: Payload string, e.g. ``{opcode=OP_ADD, rd=5}``

    Returns:
        Parsed Python object (dict, list, int, or str).

    Raises:
        ParseError: If the string cannot be parsed.
    """
    text = text.strip()
    if not text:
        return {}
    val, _ = _parse_value(text, 0)
    return val


def parse_line(line: str) -> Optional[LogEntry]:
    """Parse a single structured log line.

    Expected formats::

        [<time>] | <EVENT> | <payload>                          (RTL)
        HH:MM:SS:module:LEVEL   :[<time>] | <EVENT> | <payload>  (pysim)

    For pysim logs the ``timestamp:module:level:`` prefix is stripped
    automatically so downstream code sees the same ``LogEntry`` shape.

    Returns:
        A ``LogEntry``, or ``None`` if the line doesn't match the format.
    """
    line = line.rstrip("\n")

    # For pysim logs, strip "HH:MM:SS:module:LEVEL:" prefix.
    # The structured part always starts with ":[step]", so find that.
    if not line.startswith("["):
        bracket_idx = line.find(":[")
        if bracket_idx >= 0:
            line = line[bracket_idx + 1:]  # keep "[step] | ..."
        else:
            return None

    parts = line.split(" | ", 2)
    if len(parts) < 2:
        return None

    # Parse timestamp
    time_str = parts[0].strip()
    if not time_str.startswith("[") or not time_str.endswith("]"):
        return None
    try:
        time_val = int(time_str[1:-1].strip())
    except ValueError:
        return None

    event = parts[1].strip()

    # Payload is optional (some events have no fields)
    if len(parts) == 3:
        try:
            payload = parse_payload(parts[2])
        except ParseError:
            # Fall back to raw string if payload can't be parsed
            payload = parts[2].strip()
    else:
        payload = {}

    return LogEntry(time=time_val, event=event, payload=payload, raw=line)


def parse_file(
    path: Union[str, Path],
    events: Optional[set[str]] = None,
) -> list[LogEntry]:
    """Parse all structured log lines from a file.

    Args:
        path: Path to the log file.
        events: If given, only include entries whose event is in this set.
            Example: ``{"EXECUTE", "STALL_START"}``

    Returns:
        List of ``LogEntry`` objects, in file order.
    """
    # Fast path: use grep-based pre-filtering when events are specified
    if events:
        try:
            from .fast_search import fast_parse_file
            return fast_parse_file(path, events)
        except ImportError:
            pass

    entries: list[LogEntry] = []
    with open(path) as f:
        for line in f:
            entry = parse_line(line)
            if entry is None:
                continue
            if events and entry.event not in events:
                continue
            entries.append(entry)
    return entries
