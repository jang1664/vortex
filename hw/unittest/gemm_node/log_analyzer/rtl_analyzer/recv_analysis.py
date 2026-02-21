"""RECV pattern analysis for IMCE instruction traces."""

import re
from pathlib import Path
from typing import Optional


def count_recv_before_step(log_file: Path, imce_name: str, rd_filter: Optional[int] = None) -> list[dict]:
    """
    Parse log file and count successful OP_RECV before each OP_STEP success.

    Args:
        log_file: Path to the log file (e.g., now.debug.log)
        imce_name: IMCE identifier (e.g., "IMCE.2.1")
        rd_filter: If set, only count OP_RECV with this rd value (e.g., 0 for load_lb)

    Returns:
        List of dicts with step_index, recv_count, pc, uid info
    """
    # Pattern to match successful instruction lines for the specific IMCE
    # Example: IMCE.3.1 | SUC INST | PC : 0 | NEXT_PC : 1 | OP_RECV({...})
    pattern = re.compile(
        rf'{re.escape(imce_name)}\s*\|\s*SUC INST\s*\|.*\|\s*(OP_RECV|OP_STEP)'
    )
    # Pattern to extract PC value
    pc_pattern = re.compile(r'PC\s*:\s*(\d+)')
    # Pattern to extract uid value
    uid_pattern = re.compile(r'uid:(\d+)')
    # Pattern to extract rd value from OP_RECV
    rd_pattern = re.compile(r"'rd':\s*(\d+)")

    results = []
    recv_count = 0

    with open(log_file, 'r') as f:
        for line in f:
            match = pattern.search(line)
            if match:
                op_type = match.group(1)
                if op_type == 'OP_RECV':
                    if rd_filter is not None:
                        rd_match = rd_pattern.search(line)
                        if rd_match and int(rd_match.group(1)) == rd_filter:
                            recv_count += 1
                    else:
                        recv_count += 1
                elif op_type == 'OP_STEP':
                    # Extract PC and uid from line
                    pc_match = pc_pattern.search(line)
                    uid_match = uid_pattern.search(line)
                    pc = int(pc_match.group(1)) if pc_match else -1
                    uid = int(uid_match.group(1)) if uid_match else -1

                    results.append({
                        'step_index': len(results),
                        'recv_count': recv_count,
                        'pc': pc,
                        'uid': uid,
                    })
                    recv_count = 0  # Reset for next STEP

    return results


def expand_row_pattern(pattern: list) -> list[int]:
    """
    Expand a nested row pattern into a flat list of load_lb counts before each STEP.

    Args:
        pattern: Nested pattern like [{'count': 1, 'pattern': [{'count': 1, 'pattern': 10}, ...]}, ...]

    Returns:
        Flat list of expected load_lb counts, one per STEP
    """
    def expand_inner(inner_pattern):
        """Expand inner pattern recursively."""
        expanded = []
        for item in inner_pattern:
            count = item['count']
            pat = item['pattern']
            if isinstance(pat, int):
                # Base case: pat is the load_lb count
                expanded.extend([pat] * count)
            elif isinstance(pat, list):
                # Recursive case: pat is another nested pattern
                inner_expanded = expand_inner(pat)
                expanded.extend(inner_expanded * count)
        return expanded

    return expand_inner(pattern)


def parse_expected_patterns_from_log(log_file: Path) -> dict[int, list[int]]:
    """
    Parse expected row patterns for each node from test_random.log.

    Args:
        log_file: Path to test_random.log

    Returns:
        Dict mapping node_id to expanded flat list of expected load_lb counts
    """
    import ast

    node_patterns = {}
    # Pattern to find node header (handles quoted or unquoted lines)
    pattern_regex = re.compile(r"row pattern for node (\d+):")

    with open(log_file, 'r') as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        # Strip quotes from line if present (log file may have quoted lines)
        line = lines[i].strip()
        if line.startswith("'") and line.endswith("'"):
            line = line[1:-1]

        match = pattern_regex.search(line)
        if match:
            node_id = int(match.group(1))
            # Collect pattern lines until we hit a non-pattern line
            pattern_str = ""
            i += 1
            while i < len(lines):
                stripped = lines[i].strip()

                # Check if this line is part of the pattern
                # Pattern lines contain 'count' and/or 'pattern' dict keys
                if "'count'" in stripped or "'pattern'" in stripped:
                    pattern_str += stripped
                    i += 1
                else:
                    break

            # Try to parse the pattern
            if pattern_str:
                try:
                    pattern = ast.literal_eval(pattern_str)
                    expanded = expand_row_pattern(pattern)
                    node_patterns[node_id] = expanded
                except (SyntaxError, ValueError):
                    pass  # Skip patterns that can't be parsed
        else:
            i += 1

    return node_patterns


def compare_recv_patterns(
    actual: list[dict],
    expected: list[int],
) -> dict:
    """
    Compare actual RECV counts with expected pattern.

    Args:
        actual: List of dicts from count_recv_before_step
        expected: Flat list of expected load_lb counts from expand_row_pattern

    Returns:
        Dict with comparison results
    """
    actual_counts = [r['recv_count'] for r in actual]

    matches = 0
    mismatches = []

    min_len = min(len(actual_counts), len(expected))
    for i in range(min_len):
        if actual_counts[i] == expected[i]:
            matches += 1
        else:
            mismatches.append({
                'index': i,
                'actual': actual_counts[i],
                'expected': expected[i],
                'pc': actual[i]['pc'] if i < len(actual) else -1,
            })

    return {
        'actual_count': len(actual_counts),
        'expected_count': len(expected),
        'matches': matches,
        'mismatches': mismatches,
        'actual_counts': actual_counts,
        'expected_counts': expected,
    }
