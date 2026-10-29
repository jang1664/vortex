#!/usr/bin/env python3
"""Classify all AFU AXI addresses for a standalone C4 production resident run.

Run check_dma_trace.py as well: it validates every beat of GEMM DMA bursts.
CPU cache lines and external data beats are 64 bytes on this fixed C4 config.
Runtime arguments, stack, code, performance writes and fence reads are counted
separately from attention tensors. Counts include startup and kernel exit.
"""

import argparse
import gzip
import collections
import json
import re
from pathlib import Path

from check_dma_trace import logical_address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-log", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--dma-audit", required=True, type=Path)
    parser.add_argument("--decoder-manifest", type=Path)
    parser.add_argument("--kernel-elf", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    app = args.app_log.read_text()
    dma = json.loads(args.dma_audit.read_text())
    if (not dma["passed"] or dma["burst_counts"].get("AW", 0)
            or Path(dma["trace"]).resolve() != args.trace.resolve()
            or Path(dma["app_log"]).resolve() != args.app_log.resolve()):
        parser.error("requires a passing DMA audit of these exact logs, without writes")
    manifest = None
    if args.decoder_manifest:
        from decoder_traffic_manifest import DecoderTrafficManifest
        manifest = DecoderTrafficManifest(args.decoder_manifest)
        manifest.check_app(app)
        if Path(dma.get("decoder_manifest", "")).resolve() != args.decoder_manifest.resolve():
            parser.error("DMA audit must use this exact decoder manifest")
    if not manifest and "Device: cores=1, warps=4, threads=16" not in app:
        parser.error("this auditor is specific to the single-core C4 configuration")
    tensors = {name: (int(address, 16), int(size)) for name, address, size in
               re.findall(r"HBM_RANGE name=(\w+) address=(0x[0-9a-f]+) bytes=(\d+)", app)}
    if manifest:
        tensors = manifest.ranges
    elif len(tensors) != 7:
        parser.error("requires named tensor ranges")
    code = re.findall(r"MEM_RESERVE:.*address=(0x[0-9a-f]+), size=(\d+)", app)
    allocations = re.findall(r"MEM_ALLOC:.*size=(\d+),", app)
    if len(code) != 1 or (not manifest and len(allocations) != 1):
        parser.error("requires one kernel reservation and one argument allocation")
    code_start, code_size = int(code[0][0], 16), int(code[0][1])
    args_size = (int(manifest.data["dispatch"]["bytes"]) if manifest else int(allocations[0]))
    # VX_config STACK_BASE_ADDR/STACK_LOG2_SIZE and vx_start.S, one 8 KiB stack/hart.
    runtime = {"code": (code_start, (code_size + 63) // 64 * 64),
               "stack": (0x1FFC00000 - 64 * 8192, 64 * 8192),
               "performance": (0x80, 256)}
    runtime_contract = None
    if args.kernel_elf:
        if not manifest:
            parser.error("--kernel-elf requires --decoder-manifest")
        from decoder_runtime import from_elf
        runtime_contract = from_elf(args.kernel_elf, manifest.data["geometry"], code_start, code_size)
        runtime["runtime_tls"] = runtime_contract["tls"]
    if manifest:
        runtime.update(manifest.runtime_ranges)
        manifest.check_disjoint(dict(tensors, **runtime))
    requests = collections.Counter()
    write_counts = collections.Counter()
    response_beats = 0
    write_valid_bytes = 0
    write_beats = 0
    argument_parts = [None, None]
    register_argument_parts = [None, None]
    dcr_register_address = None

    def argument_address():
        parts = argument_parts if None not in argument_parts else register_argument_parts
        return 0 if None in parts else parts[0] | parts[1] << 32

    unexpected = 0
    examples = []
    flush_uuids = set()
    pending_fence_reads = 0
    write_addresses = collections.defaultdict(collections.deque)
    write_strobes = collections.defaultdict(collections.deque)

    def consume_writes(port):
        nonlocal unexpected
        while write_addresses[port] and write_strobes[port]:
            number, address = write_addresses[port].popleft()
            strobe_number, strobe = write_strobes[port].popleft()
            ranges = dict(tensors, **runtime)
            names = [name for name,(base,size) in ranges.items()
                     if base <= address and address+64 <= base+size]
            category = names[0] if len(names) == 1 else "unclassified"
            valid_strobe = 0 < strobe < (1<<64)
            if runtime_contract and valid_strobe:
                from decoder_runtime import write_region
                precise = write_region(address, strobe, runtime_contract)
                if precise: category = precise
            allowed = valid_strobe and category in (manifest.writable | {"stack", "arguments", "performance"})
            if runtime_contract and category in {"runtime_bss", "runtime_tls"}:
                from decoder_runtime import write_region
                allowed = valid_strobe and write_region(address, strobe, runtime_contract) == category
            write_counts[category] += 1
            requests[f"Wr:{category}"] += 1
            if not allowed:
                unexpected += 1
                if len(examples) < 16:
                    examples.append(dict(line=number, strobe_line=strobe_number, direction="Wr", port=port,
                                         logical=hex(address), strobe=hex(strobe), category=category))

    pattern = re.compile(r"(\d+): AXI (Rd|Wr) Req \[(\d+)\]: addr=(0x[0-9a-f]+)")
    with (gzip.open(args.trace, "rt") if args.trace.suffix == ".gz" else args.trace.open()) as trace:
        for number, line in enumerate(trace, 1):
            if "base-dcr: state=STARTUP_ARG" in line:
                match = re.search(r"STARTUP_ARG([01]), data=(0x[0-9a-f]+)", line)
                argument_parts[int(match[1])] = int(match[2], 16)
            if "[TB] REG_WRITE:" in line:
                # The selective trace omits the PIPELINE-gated base-DCR log.
                # Decode the actual serialized AXI-Lite control commands instead:
                # runtime/xrt/vortex.cpp MMIO_DCR_ADDR=0x20, data=0x24;
                # VX_types.vh STARTUP_ARG0/1=0x003/0x004. The testbench completes
                # each register transaction before consuming the next command.
                match = re.search(r"offset=(0x[0-9a-f]+) value=(0x[0-9a-f]+)", line)
                offset, value = (int(part, 16) for part in match.groups())
                if offset == 0x20:
                    dcr_register_address = value
                elif offset == 0x24 and dcr_register_address in (3, 4):
                    register_argument_parts[dcr_register_address - 3] = value
            if "tags-flush:" in line:
                flush_uuids.add(int(re.search(r"\(#(\d+)\)", line)[1]))
            if "MEM Rd Req[" in line and "addr=0x0," in line:
                uuid = int(re.search(r"\(#(\d+)\)", line)[1])
                if uuid in flush_uuids:
                    pending_fence_reads += 1
            if "AXI" not in line:
                continue
            if "AXI Rd Rsp" in line:
                response_beats += 1
            strobe = re.search(r"AXI Wr Req \[(\d+)\]: strb=(0x[0-9a-f]+)", line)
            if strobe:
                write_beats += 1
                write_valid_bytes += int(strobe[2], 16).bit_count()
                if manifest:
                    port = int(strobe[1])
                    write_strobes[port].append((number, int(strobe[2], 16)))
                    consume_writes(port)
            match = pattern.search(line)
            if not match:
                continue
            time, direction, port, physical = match.groups()
            address = logical_address(int(physical, 16))
            if direction == "Wr" and manifest:
                write_addresses[int(port)].append((number, address))
                consume_writes(int(port))
                continue
            arg_start = argument_address()
            ranges = dict(tensors, **runtime)
            if arg_start and not manifest:
                ranges["arguments"] = (arg_start & ~63,
                    ((arg_start % 64 + args_size + 63) // 64) * 64)
            names = [name for name, (base, size) in ranges.items()
                     if base <= address and address + 64 <= base + size]
            if address == 0 and direction == "Rd" and pending_fence_reads:
                # Match a preceding zero-address MEM request with the same UUID
                # as a cache flush. The final fence need not print "fence wait".
                names = ["fence"]
                pending_fence_reads -= 1
            category = names[0] if len(names) == 1 else "unclassified"
            allowed = len(names) == 1
            if direction == "Wr":
                writable = {"output", "stack", "arguments", "performance"}
                if manifest:
                    writable = manifest.writable | {"stack", "arguments", "performance"}
                allowed &= category in writable
                write_counts[category] += 1
            else:
                allowed &= category != "performance"
            requests[f"{direction}:{category}"] += 1
            if not allowed:
                unexpected += 1
                if len(examples) < 16:
                    examples.append(dict(line=number, direction=direction, port=int(port),
                                         logical=hex(address), category=category))
    read_requests = sum(count for key, count in requests.items() if key.startswith("Rd:"))
    write_requests = sum(write_counts.values())
    # No GEMM stores; remaining AFU writes are single-beat CPU cache/MMIO writes.
    sources = {}
    if None not in argument_parts:
        sources["base_dcr"] = argument_parts[0] | argument_parts[1] << 32
    if None not in register_argument_parts:
        sources["axi_lite_registers"] = (register_argument_parts[0]
                                        | register_argument_parts[1] << 32)
    sources_agree = bool(sources) and len(set(sources.values())) == 1
    output_name = "context" if manifest else "output"
    dispatch_matches = not manifest or argument_address() == manifest.dispatch_base
    unmatched_writes = sum(map(len,write_addresses.values())) + sum(map(len,write_strobes.values()))
    passed = (sources_agree and dispatch_matches and argument_address() != 0 and not unmatched_writes
              and read_requests > 0 and response_beats >= read_requests
              and write_requests == write_beats and requests[f"Wr:{output_name}"] > 0
              and not unexpected and pending_fence_reads == 0)
    result = dict(passed=passed, scope="All AFU AXI requests, including runtime",
                  requests_by_region=dict(requests),
                  read_response_beats=response_beats,
                  read_payload_bytes=response_beats * 64,
                  write_beats=write_beats, write_bus_bytes=write_beats * 64,
                  write_valid_bytes=write_valid_bytes,
                  unexpected_requests=unexpected, first_failures=examples,
                  argument_address=hex(argument_address()),
                  argument_address_sources={name: hex(value) for name, value in sources.items()},
                  argument_sources_agree=sources_agree,
                  argument_bytes=args_size, dma_audit=str(args.dma_audit),
                  app_log=str(args.app_log), trace=str(args.trace))
    if manifest:
        result.update(decoder_manifest=str(args.decoder_manifest), dispatch_matches=dispatch_matches,
                      unmatched_write_events=unmatched_writes, runtime_contract=runtime_contract,
                      argument_array_base=hex(manifest.args_base),
                      input_adapter_write_requests=sum(write_counts[name] for name in manifest.writable
                                                       if name != "context"))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
