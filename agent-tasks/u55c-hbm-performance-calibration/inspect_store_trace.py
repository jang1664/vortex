#!/usr/bin/env python3
"""Pair single-beat AW/W trace records and inspect the vecadd result buffer."""
import argparse
from collections import defaultdict
import json
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log')
args = parser.parse_args()
aw, w, totals = defaultdict(list), defaultdict(list), {}
with open(args.log) as stream:
    for line in stream:
        a = re.search(r'REFERENCE_STORE_AW t=(\d+) port=(\d+) addr=([\da-fxz]+) len=([\da-fxz]+)', line, re.I)
        b = re.search(r'REFERENCE_STORE_W t=(\d+) port=(\d+) strb=([\da-fxz]+) data=([\da-fxz]+)', line, re.I)
        total = re.search(r'REFERENCE_STORE_TOTAL port=(\d+) aw=(\d+) w=(\d+)', line)
        if a:
            time, port, address, length = a.groups()
            if length != '00':
                raise ValueError('Only single-beat trace pairing is supported')
            aw[int(port)].append((int(time), int(address, 16)))
        if b:
            time, port, strobe, data = b.groups()
            if len(data) != 128:
                raise ValueError('Expected complete 512-bit write data')
            w[int(port)].append((int(time), int(strobe, 16), data))
        if total:
            port, na, nw = map(int, total.groups())
            totals[port] = (na, nw)
if not totals:
    raise ValueError('Missing final counters')
targets = {0x20000800, 0xa0000800, 0x120000800, 0x1a0000800}
result = []
for port, (na, nw) in totals.items():
    if not (len(aw[port]) == na == nw == len(w[port])):
        raise ValueError(f'Incomplete trace for port {port}')
    for (at, addr), (wt, strobe, data) in zip(aw[port], w[port]):
        if addr in targets:
            active = {str(i): data[-2*(i+1):len(data)-2*i] for i in range(64) if strobe & (1 << i)}
            result.append({'port': port, 'address': hex(addr), 'aw_time_ps': at,
                           'w_time_ps': wt, 'strobe': hex(strobe), 'active_bytes': active,
                           'unknown_active_bytes': sum(bool(re.search('[xz]', byte, re.I)) for byte in active.values())})
print(json.dumps({'per_port_counts': totals, 'result_buffer_writes': result}, indent=2))
