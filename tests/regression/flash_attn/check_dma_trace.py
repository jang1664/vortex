#!/usr/bin/env python3
"""Audit C4 GEMM DMA bursts against a production resident run's input ranges.

This checks the GEMM DMA master, not CPU cache traffic. AXI addresses are
inverted using the rev8 C4 geometry from VX_mem_remap (32 banks, 4 ports,
64-byte blocks, 34-bit address space). Do not use for a different geometry.
"""

import argparse
import gzip
import collections
import json
import re
from pathlib import Path


def logical_address(physical):
    bank, offset = divmod(physical, 1 << 29)
    if bank >= 32:
        raise ValueError(f"physical address outside C4 HBM: {physical:#x}")
    row, byte = divmod(offset, 64)
    port, local_bank = divmod(bank, 8)
    return ((row * 8 + local_bank) * 4 + port) * 64 + byte


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-log", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--ranges", type=Path,
                        help="Explicit historical range JSON {name: [address, bytes]}")
    parser.add_argument("--decoder-manifest", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    app = args.app_log.read_text()
    manifest = None
    if args.decoder_manifest:
        from decoder_traffic_manifest import DecoderTrafficManifest
        manifest = DecoderTrafficManifest(args.decoder_manifest)
        manifest.check_app(app)
        if args.ranges:
            parser.error("decoder manifest cannot be combined with historical standalone ranges")
    elif "resident=1, diagnostics=0" not in app or "\nPASSED\n" not in app:
        parser.error("requires a successful production resident run without exports")
    ranges = {name: (int(address, 16), int(size)) for name, address, size in
              re.findall(r"HBM_RANGE name=(\w+) address=(0x[0-9a-f]+) bytes=(\d+)", app)}
    if args.ranges:
        ranges = json.loads(args.ranges.read_text())
    required = {"q", "k_weight", "k_scale", "zero", "v_weight", "v_scale", "output"}
    if manifest:
        ranges = manifest.ranges
        required = set(manifest.expected_bytes)
    elif set(ranges) != required:
        parser.error("requires exact named input/output range manifest")
    for name, (base, size) in ranges.items():
        if size <= 0 or base < 0:
            parser.error(f"invalid range {name}")
    burst = re.compile(r"gemm:tmem:dma ch=(\d+) (AR|AW)_FIRE addr=(0x[0-9a-f]+) len=(\d+)")
    counts = collections.Counter()
    observed_beats = collections.Counter()
    bursts = collections.Counter()
    failures = []
    unexpected_count = 0
    with (gzip.open(args.trace, "rt") if args.trace.suffix == ".gz" else args.trace.open()) as trace:
        for number, line in enumerate(trace, 1):
            match = burst.search(line)
            if not match:
                continue
            channel, direction, address, length = match.groups()
            bursts[direction] += 1
            for beat in range(int(length) + 1):
                physical = int(address, 16) + beat * 64
                logical = logical_address(physical)
                names = [name for name, (base, size) in ranges.items()
                         if base <= logical and logical + 64 <= base + size]
                allowed = direction == "AR" and len(names) == 1 and names[0] != "output"
                if manifest:
                    allowed = allowed and logical in manifest.expected_beats
                    if direction == "AR": observed_beats[logical] += 1
                if not allowed:
                    unexpected_count += 1
                    if len(failures) < 16:
                        failures.append(dict(line=number, channel=int(channel),
                                             direction=direction, physical=hex(physical),
                                             logical=hex(logical), matching_ranges=names))
                else:
                    counts[names[0]] += 64
    missing = sorted(required - {"output"} - counts.keys())
    expected_bytes = {name: size * (2 if name == "zero" else 1)
                      for name, (_, size) in ranges.items() if name != "output"}
    if manifest:
        expected_bytes = dict(manifest.expected_bytes)
    count_mismatches = {name: dict(actual=counts[name], expected=size)
                        for name, size in expected_bytes.items() if counts[name] != size}
    beat_mismatches = []
    if manifest:
        beat_mismatches = [dict(address=hex(address), actual=observed_beats[address],
                                expected=manifest.expected_beats[address])
                           for address in sorted(observed_beats.keys() | manifest.expected_beats.keys())
                           if observed_beats[address] != manifest.expected_beats[address]]
    passed = (bool(bursts["AR"]) and not unexpected_count and not missing
              and not count_mismatches and not beat_mismatches)
    result = dict(passed=passed, scope="GEMM DMA master only; CPU cache traffic is separate",
                  geometry=dict(banks=32, ports=4, block_bytes=64, address_bits=34),
                  read_bytes_by_input=dict(counts), burst_counts=dict(bursts),
                  unexpected_beats=unexpected_count, missing_inputs=missing,
                  byte_count_mismatches=count_mismatches,
                  first_failures=failures, app_log=str(args.app_log), trace=str(args.trace))
    if manifest:
        result.update(decoder_manifest=str(args.decoder_manifest), expected_gemm_jobs=manifest.expected_jobs,
                      expected_read_bytes=sum(expected_bytes.values()),
                      address_mismatch_count=len(beat_mismatches), first_address_mismatches=beat_mismatches[:16])
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
