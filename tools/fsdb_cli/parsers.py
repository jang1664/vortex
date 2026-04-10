"""Parsers for FSDB utility outputs.

Converts raw text output from fsdbdebug/fsdbreport into structured data.
"""

import csv
import io
import re
from dataclasses import dataclass, field


@dataclass
class VarInfo:
    """Signal variable metadata from fsdbdebug -tree."""
    name: str
    type: str  # vcd_reg, vcd_wire, vcd_integer, string, etc.
    bits: str  # e.g., '[31:0]', '' for 1-bit
    left: int
    right: int
    id: int
    width: int


@dataclass
class ScopeNode:
    """A node in the FSDB hierarchy tree."""
    name: str
    type: str  # vcd_module, vcd_task, vcd_begin, etc.
    children: list["ScopeNode"] = field(default_factory=list)
    vars: list[VarInfo] = field(default_factory=list)
    parent: "ScopeNode | None" = field(default=None, repr=False)


@dataclass
class FsdbInfo:
    """FSDB file metadata from fsdbdebug -info."""
    fsdb_version: str = ""
    file_status: str = ""
    file_type: str = ""
    scale_unit: str = ""
    simulation_date: str = ""
    simulator_version: str = ""
    simulator_type: str = ""
    min_time: str = ""
    max_time: str = ""
    scope_count: int = 0
    var_count: int = 0
    max_var_idcode: int = 0
    extra: dict = field(default_factory=dict)


def parse_fsdb_info(raw: str) -> FsdbInfo:
    """Parse fsdbdebug -info output into FsdbInfo."""
    info = FsdbInfo()
    for line in raw.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower()
        val = val.strip()
        mapping = {
            "fsdb version": "fsdb_version",
            "file status": "file_status",
            "file type": "file_type",
            "scale unit": "scale_unit",
            "simulation date": "simulation_date",
            "simulator version": "simulator_version",
            "simulator type": "simulator_type",
            "minimum xtag": "min_time",
            "maximum xtag": "max_time",
            "scope creation cnt": "scope_count",
            "var creation cnt": "var_count",
            "max var idcode": "max_var_idcode",
        }
        matched = False
        for k, attr in mapping.items():
            if key == k:
                setattr(info, attr, val)
                matched = True
                break
        if not matched:
            info.extra[key] = val
    return info


def _find_or_create_child(parent: ScopeNode, name: str, scope_type: str) -> ScopeNode:
    """Find existing child by name or create a new one.

    VCS creates multiple scopes with the same name (different dump sessions).
    We merge them so the hierarchy tree shows each module once.
    """
    for child in parent.children:
        if child.name == name:
            return child
    node = ScopeNode(name=name, type=scope_type, parent=parent)
    parent.children.append(node)
    return node


def _parse_var_line(stripped: str) -> VarInfo | None:
    """Parse a single Var: line from fsdbdebug -tree output."""
    m = re.match(
        r'Var:\s+(\S+)\s+(.+?)\s+l:(\d+)\s+r:(\d+)\s+\S+\s+(\d+)\s+(\d+)B',
        stripped,
    )
    if m:
        vtype, full_name, left, right, vid, width = m.groups()
        bits_match = re.search(r'\[([\d:]+)\]$', full_name)
        bits = bits_match.group(1) if bits_match else ""
        return VarInfo(
            name=full_name.strip(),
            type=vtype,
            bits=bits,
            left=int(left),
            right=int(right),
            id=int(vid),
            width=int(width),
        )
    return None


def parse_scope_tree(raw: str) -> ScopeNode:
    """Parse fsdbdebug -scope output into a tree (scopes only)."""
    root = ScopeNode(name="<root>", type="root")
    current = root
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("Scope:"):
            parts = stripped.split()
            if len(parts) >= 3:
                scope_type = parts[1]
                scope_name = parts[2]
                current = _find_or_create_child(current, scope_name, scope_type)
        elif stripped == "Upscope:":
            if current.parent is not None:
                current = current.parent
    return root


def parse_full_tree(raw: str) -> ScopeNode:
    """Parse fsdbdebug -tree output into a tree (scopes + signals).

    WARNING: On large FSDB files (millions of signals), this is very slow.
    Prefer parse_tree_scoped() for targeted scope queries.
    """
    root = ScopeNode(name="<root>", type="root")
    current = root
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("Scope:"):
            parts = stripped.split()
            if len(parts) >= 3:
                scope_type = parts[1]
                scope_name = parts[2]
                current = _find_or_create_child(current, scope_name, scope_type)
        elif stripped.startswith("Var:"):
            var = _parse_var_line(stripped)
            if var:
                if not any(v.name == var.name for v in current.vars):
                    current.vars.append(var)
        elif stripped == "Upscope:":
            if current.parent is not None:
                current = current.parent
    return root


def parse_tree_scoped(
    raw_iter,
    target_scope: list[str],
    max_depth: int | None = None,
) -> ScopeNode:
    """Streaming parse of fsdbdebug -tree output for a specific scope.

    Instead of building the full tree, streams through the output tracking
    scope depth and only collects vars within the target scope window.
    Skips all data outside the target scope for speed.

    Args:
        raw_iter: Iterable of lines (e.g., subprocess stdout).
        target_scope: Path parts to the target (e.g., ['tb', 'dut', 'u_core']).
        max_depth: Max depth below target to collect. None = unlimited.

    Returns:
        ScopeNode tree rooted at the target scope, with vars populated.
    """
    target_depth = len(target_scope)
    # Current scope path during streaming
    scope_stack: list[tuple[str, str]] = []  # [(name, type)]
    # Track if we're inside the target scope
    in_target = False
    target_node = None
    # Build tree relative to target
    current_node: ScopeNode | None = None
    node_stack: list[ScopeNode] = []

    def _matches_target(stack):
        if len(stack) < target_depth:
            return False
        for i, part in enumerate(target_scope):
            if stack[i][0] != part:
                return False
        return True

    for line in raw_iter:
        stripped = line.strip()

        if stripped.startswith("Scope:"):
            parts = stripped.split()
            if len(parts) >= 3:
                scope_type = parts[1]
                scope_name = parts[2]
                scope_stack.append((scope_name, scope_type))

                if _matches_target(scope_stack):
                    in_target = True
                    rel_depth = len(scope_stack) - target_depth
                    if max_depth is not None and rel_depth > max_depth:
                        continue
                    new_node = ScopeNode(name=scope_name, type=scope_type)
                    if current_node is not None:
                        new_node.parent = current_node
                        current_node.children.append(new_node)
                    else:
                        target_node = new_node
                    node_stack.append(current_node)
                    current_node = new_node
                elif in_target and len(scope_stack) <= target_depth:
                    # We were in target, now leaving it
                    in_target = False

        elif stripped.startswith("Var:"):
            if in_target and current_node is not None:
                rel_depth = len(scope_stack) - target_depth
                if max_depth is None or rel_depth <= max_depth:
                    var = _parse_var_line(stripped)
                    if var:
                        current_node.vars.append(var)

        elif stripped == "Upscope:":
            if scope_stack:
                scope_stack.pop()
            if in_target:
                rel_depth = len(scope_stack) - target_depth + 1
                if rel_depth <= (max_depth if max_depth is not None else 9999):
                    if node_stack:
                        current_node = node_stack.pop()
                if len(scope_stack) < target_depth:
                    in_target = False

    return target_node or ScopeNode(name="<empty>", type="root")


def _fmt_var_one_liner(v: VarInfo) -> str:
    """Format a VarInfo as a compact single-line description."""
    return f"{v.name}  ({v.type})"


def format_scope_tree(node: ScopeNode, prefix: str = "", is_last: bool = True,
                       max_depth: int | None = None, show_vars: bool = False,
                       depth: int = 0) -> list[str]:
    """Format a ScopeNode tree as indented text lines."""
    if max_depth is not None and depth > max_depth:
        return []

    lines = []
    connector = "└── " if is_last else "├── "
    if depth == 0:
        lines.append(f"{node.name}/")
    else:
        lines.append(f"{prefix}{connector}{node.name}/")

    child_prefix = prefix + ("    " if is_last else "│   ")

    # Show vars at this scope (leaf depth or when vars requested)
    if show_vars and node.vars:
        var_prefix = child_prefix
        for i, v in enumerate(node.vars):
            vmark = "└── " if (not node.children and i == len(node.vars) - 1) else "├── "
            lines.append(f"{var_prefix}{vmark}{_fmt_var_one_liner(v)}")

    for i, child in enumerate(node.children):
        last = (i == len(node.children) - 1)
        lines.extend(format_scope_tree(
            child, child_prefix, last, max_depth, show_vars, depth + 1,
        ))
    return lines


def format_scope_flat(node: ScopeNode, prefix: str = "",
                      max_depth: int | None = None, show_vars: bool = False,
                      depth: int = 0) -> list[str]:
    """Format a ScopeNode tree as flat full-path lines.

    Each line is a complete path that can be copied directly for use
    with other commands (e.g., events -s, cut -s).
    """
    if max_depth is not None and depth > max_depth:
        return []

    # Build the path: prefix + current node name
    if depth == 0:
        path = prefix  # root/skip node, carry prefix forward
    else:
        path = f"{prefix}/{node.name}" if prefix else node.name

    lines = []
    if depth > 0:
        lines.append(f"{path}/")

    if show_vars and node.vars:
        for v in node.vars:
            lines.append(f"{path}/{v.name}")

    for child in node.children:
        lines.extend(format_scope_flat(
            child, path, max_depth, show_vars, depth + 1,
        ))
    return lines


def parse_tree_vars(raw: str) -> list[VarInfo]:
    """Parse fsdbdebug -tree output to extract Var: entries."""
    vars = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped.startswith("Var:"):
            continue
        # Var: type name[bits] l:X r:X implicit id widthB flags
        # e.g., Var: vcd_reg clk l:0 r:0 implicit 6 1B 0
        # e.g., Var: vcd_reg input_mat[0][15:0] l:15 r:0 implicit 13 1B 0
        m = re.match(
            r'Var:\s+(\S+)\s+(.+?)\s+l:(\d+)\s+r:(\d+)\s+\S+\s+(\d+)\s+(\d+)B',
            stripped,
        )
        if m:
            vtype, full_name, left, right, vid, width = m.groups()
            # Extract bits suffix like [31:0] if present
            bits_match = re.search(r'\[([\d:]+)\]$', full_name)
            bits = bits_match.group(1) if bits_match else ""
            clean_name = full_name.rstrip()
            vars.append(VarInfo(
                name=clean_name,
                type=vtype,
                bits=bits,
                left=int(left),
                right=int(right),
                id=int(vid),
                width=int(width),
            ))
    return vars


def parse_csv_report(raw: str) -> tuple[str, list[str], list[list[str]]]:
    """Parse fsdbreport -csv output.

    Returns:
        (time_unit, signal_names, rows)
        where each row is [timestamp, val1, val2, ...]
    """
    reader = csv.reader(io.StringIO(raw))
    rows = list(reader)
    if not rows:
        return ("", [], [])

    header = rows[0]
    if not header or not header[0].startswith("Time("):
        return ("", [], [])

    # Parse time unit from header: "Time(1ps)" -> "1ps"
    time_col = header[0]
    m = re.match(r'Time\((\w+)\)', time_col)
    time_unit = m.group(1) if m else ""

    signal_names = header[1:]
    data_rows = rows[1:]

    # Filter out empty rows
    data_rows = [r for r in data_rows if r and any(c.strip() for c in r)]

    return (time_unit, signal_names, data_rows)


def format_csv_table(
    time_unit: str,
    signal_names: list[str],
    data_rows: list[list[str]],
    signal_width: int | None = None,
) -> str:
    """Format parsed CSV data as an aligned table."""
    if not signal_names and not data_rows:
        return "(no data)"

    # Compute column widths
    time_header = f"Time({time_unit})" if time_unit else "Time"
    col_widths = [len(time_header)]
    for name in signal_names:
        # Use full signal path or basename
        display = name.split("/")[-1] if "/" in name else name
        col_widths.append(max(len(display), signal_width or 0))

    for row in data_rows:
        for i, val in enumerate(row):
            if i < len(col_widths):
                col_widths[i] = max(col_widths[i], len(val.strip()))

    # Format header
    header_names = [time_header]
    for name in signal_names:
        display = name.split("/")[-1] if "/" in name else name
        header_names.append(display)

    lines = []
    header_line = "  ".join(
        n.ljust(w) for n, w in zip(header_names, col_widths)
    )
    sep_line = "  ".join("=" * w for w in col_widths)
    lines.append(header_line)
    lines.append(sep_line)

    # Format data rows
    for row in data_rows:
        padded = []
        for i, val in enumerate(row):
            v = val.strip() if i < len(row) else ""
            w = col_widths[i] if i < len(col_widths) else 0
            padded.append(v.ljust(w))
        lines.append("  ".join(padded))

    return "\n".join(lines)
