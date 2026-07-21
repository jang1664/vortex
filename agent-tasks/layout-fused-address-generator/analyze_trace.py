#!/usr/bin/env python3
"""Summarize simx DEBUG instruction traces for the optimized eladd kernel."""

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import TextIO, TypeAlias


PcRange: TypeAlias = tuple[int, int]

KERNEL_RANGE: PcRange = (0x180000094, 0x18000065C)

EXPECTED_DUMP_SHA256 = "d0d9b35053be347f0990b091a1a052f364e948fd99ab4d182e5a981c3b9ab8b6"

# DEBUG instrumentation can account for 66 more lane instructions than PERF
# in the measured traces. Keep a small margin while still rejecting truncation.
MAX_TRACE_PERF_DELTA = 128

# Compiler PCs belonging to task/layout address calculation, loop control, and
# the integer address increments feeding the three memory streams. Loads,
# stores, and FP16 conversion instructions are deliberately excluded.
ADDRESS_CONTROL_RANGES: tuple[PcRange, ...] = (
    (0x1800001D0, 0x1800002D0),
    (0x1800002F4, 0x1800002F4),
    (0x1800002FC, 0x180000314),
    (0x1800003C0, 0x1800003C8),
)

TRACE_RE = re.compile(r"tmask=(?P<tmask>[01]+), PC=0x(?P<pc>[0-9a-fA-F]+)")
PERF_RE = re.compile(r"^PERF: instrs=(?P<instructions>[0-9]+)(?:,|\s|$)")
RESULT_MARKERS = frozenset(("PASSED!", "FAILED!"))


def in_ranges(pc: int, ranges: tuple[PcRange, ...]) -> bool:
    return any(first <= pc <= last for first, last in ranges)


def is_kernel_pc(pc: int) -> bool:
    return KERNEL_RANGE[0] <= pc <= KERNEL_RANGE[1]


def is_address_control_pc(pc: int) -> bool:
    return in_ranges(pc, ADDRESS_CONTROL_RANGES)


def dump_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as dump_file:
        for chunk in iter(lambda: dump_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str, stderr: TextIO) -> int:
    print(f"error: {message}", file=stderr)
    return 1


def analyze_trace(
    input_stream: TextIO,
    dump_path: Path,
    stdout: TextIO,
    stderr: TextIO,
) -> int:
    try:
        actual_dump_sha256 = dump_sha256(dump_path)
    except OSError as error:
        return fail(f"cannot read kernel dump '{dump_path}': {error}", stderr)
    if actual_dump_sha256 != EXPECTED_DUMP_SHA256:
        return fail(
            "kernel dump SHA-256 mismatch: "
            f"expected {EXPECTED_DUMP_SHA256}, got {actual_dump_sha256}",
            stderr,
        )

    warp_instructions = 0
    lane_instructions = 0
    kernel_warp_instructions = 0
    kernel_lane_instructions = 0
    address_warp_instructions = 0
    address_lane_instructions = 0
    perf_line = ""
    perf_instructions = 0
    result_line = ""

    for line_number, line in enumerate(input_stream, start=1):
        if line.startswith("DEBUG Instr:"):
            match = TRACE_RE.search(line)
            if match is None:
                return fail(f"malformed DEBUG instruction at line {line_number}", stderr)
            active_lanes = match.group("tmask").count("1")
            pc = int(match.group("pc"), 16)
            warp_instructions += 1
            lane_instructions += active_lanes
            if is_kernel_pc(pc):
                kernel_warp_instructions += 1
                kernel_lane_instructions += active_lanes
                if is_address_control_pc(pc):
                    address_warp_instructions += 1
                    address_lane_instructions += active_lanes
        else:
            normalized = line.strip()
            if line.startswith("PERF: instrs="):
                perf_match = PERF_RE.match(normalized)
                if perf_match is None:
                    return fail(f"malformed PERF record at line {line_number}", stderr)
                perf_line = normalized
                perf_instructions = int(perf_match.group("instructions"))
            elif normalized in RESULT_MARKERS:
                result_line = normalized

    if warp_instructions == 0:
        return fail("trace contains no DEBUG instructions", stderr)
    if kernel_warp_instructions == 0 or kernel_lane_instructions == 0:
        return fail("trace contains no active kernel instructions", stderr)
    if perf_instructions <= 0:
        return fail("trace contains no positive PERF instruction count", stderr)
    trace_perf_delta = abs(lane_instructions - perf_instructions)
    if trace_perf_delta > MAX_TRACE_PERF_DELTA:
        return fail(
            "trace lane count is incomplete: "
            f"trace={lane_instructions}, PERF={perf_instructions}, "
            f"delta={trace_perf_delta} exceeds {MAX_TRACE_PERF_DELTA}",
            stderr,
        )
    if result_line != "PASSED!":
        return fail(f"terminal result is {result_line or 'missing'}, expected PASSED!", stderr)

    share = 100.0 * address_lane_instructions / kernel_lane_instructions
    print(f"trace_warp_instructions={warp_instructions}", file=stdout)
    print(f"trace_lane_instructions={lane_instructions}", file=stdout)
    print(f"kernel_warp_instructions={kernel_warp_instructions}", file=stdout)
    print(f"kernel_lane_instructions={kernel_lane_instructions}", file=stdout)
    print(f"address_control_warp_instructions={address_warp_instructions}", file=stdout)
    print(f"address_control_lane_instructions={address_lane_instructions}", file=stdout)
    print(f"address_control_share_of_kernel={share:.3f}%", file=stdout)
    print(f"kernel_dump_sha256={actual_dump_sha256}", file=stdout)
    print(perf_line, file=stdout)
    print(result_line, file=stdout)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_dump", type=Path, help="trusted kernel.dump used for PC ranges")
    args = parser.parse_args()
    return analyze_trace(sys.stdin, args.kernel_dump, sys.stdout, sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
