#!/usr/bin/env python3
"""Invert the audited 34-bit, 32-bank/8-port, 64-byte archived LSU remap."""
import argparse
from collections import Counter
import json
from pathlib import Path


def forward(address):
    block, byte = divmod(address, 64)
    q, port = divmod(block, 8)
    offset, local_bank = divmod(q, 4)
    return ((port * 4 + local_bank) << 29) | (offset << 6) | byte


def inverse(address):
    if not 0 <= address < (1 << 34):
        raise ValueError('Address outside audited 34-bit geometry')
    bank, offset = divmod(address, 1 << 29)
    block = ((offset >> 6) << 5) | ((bank & 3) << 3) | (bank >> 2)
    logical = (block << 6) | (offset & 63)
    if forward(logical) != address:
        raise ValueError('Remap round trip failed')
    return logical


def decode(trace):
    stop = trace['snapshots'][0]['time_ps']
    records = []
    for read in trace['reads']:
        if read['ar_ps'] >= stop:
            continue
        physical = int(read['address'], 16)
        logical = inverse(physical)
        delta = 0x1ffc00000 - logical
        is_stack = 0 < delta <= 64 * 8192
        kind = 'thread_stack' if is_stack else 'program_image' if 0x80000000 <= logical < 0x80002080 else 'unclassified'
        records.append({**read, 'logical_address': hex(logical), 'physical_bank': physical >> 29,
                        'classification': kind, 'thread': (delta-1)//8192 if is_stack else None})
    if len(records) != trace['startup_reads']:
        raise ValueError('Startup record count mismatch')
    stacks = [r for r in records if r['classification'] == 'thread_stack']
    return {'geometry': {'address_bits': 34, 'banks': 32, 'ports': 8, 'line_bytes': 64,
                         'stack_base': '0x1ffc00000', 'stack_bytes_per_thread': 8192, 'threads': 64,
                         'program_start': '0x80000000', 'program_end': '0x80002080'},
            'counts': dict(Counter(r['classification'] for r in records)),
            'stack_banks': dict(Counter(r['physical_bank'] for r in stacks)),
            'stack_threads': dict(sorted(Counter(r['thread'] for r in stacks).items())),
            'unique_stack_lines': len({r['logical_address'] for r in stacks}), 'records': records,
            'limitations': ['Geometry and image range are specific to the audited phase diagnostic.',
                            'Address classification does not identify load/store instructions or explain hardware timing.',
                            'Repeated line reads do not by themselves prove cache conflicts or a cache bug.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--trace', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    # Boundary/bit-position checks supplement per-record round trips.
    for address in [0, (1 << 34)-1, 0x80000000, 0x1ffbfffc0] + [1 << b for b in range(34)]:
        if inverse(forward(address)) != address:
            raise ValueError('Remap boundary test failed')
    result = decode(json.loads(a.trace.read_text()))
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('records', 'stack_threads')}, indent=2))
