#!/usr/bin/env python3
"""Pair AXI reads and CSR snapshots; outstanding time is not CPU stall time."""
import argparse
from collections import defaultdict, deque
import json
from pathlib import Path
import re
import statistics


def inspect(log):
    pending, reads, snapshots, releases = defaultdict(deque), [], [], []
    for line in log.read_text().splitlines():
        if 'Fatal:' in line:
            raise ValueError('Fatal simulator log')
        if match := re.search(r'STARTUP_CORE_RELEASE t=(\d+) cycles=(\d+)', line):
            releases.append(int(match[1]))
        if match := re.search(r'STARTUP_CYCLE_SNAPSHOT t=(\d+) cycles=(\d+)', line):
            snapshots.append({'time_ps': int(match[1]), 'cycles': int(match[2])})
        if match := re.search(r'STARTUP_AR t=(\d+) port=(\d+) id=([0-9a-f]+) addr=([0-9a-f]+) len=([0-9a-f]+)', line, re.I):
            t, port, ident, address, length = match.groups()
            request = {'ar_ps': int(t), 'port': int(port), 'id': int(ident, 16),
                       'address': '0x'+address, 'expected_beats': int(length,16)+1, 'received_beats': 0}
            pending[(request['port'], request['id'])].append(request)
        if match := re.search(r'STARTUP_R t=(\d+) port=(\d+) id=([0-9a-f]+) last=([01])', line, re.I):
            t, port, ident, last = match.groups()
            queue = pending[(int(port), int(ident,16))]
            if not queue:
                raise ValueError('Read response without request')
            request = queue[0]
            request.setdefault('first_r_ps', int(t))
            request['received_beats'] += 1
            if int(last) != (request['received_beats'] == request['expected_beats']):
                raise ValueError('Burst/last mismatch')
            if last == '1':
                request['last_r_ps'] = int(t)
                reads.append(queue.popleft())
    if any(pending.values()) or len(snapshots) != 3 or not releases:
        raise ValueError('Incomplete trace or unexpected phase snapshots')
    start, end = max(t for t in releases if t <= snapshots[0]['time_ps']), snapshots[0]['time_ps']
    early = [r for r in reads if start <= r['ar_ps'] < end]
    intervals = sorted((r['ar_ps'], min(r['last_r_ps'], end)) for r in early)
    union, right = 0, start
    for left, stop in intervals:
        union += max(0, stop-max(left,right))
        right = max(right,stop)
    latencies = [r['first_r_ps']-r['ar_ps'] for r in early]
    if not latencies:
        raise ValueError('No initial read traffic captured')
    return {'snapshots': snapshots, 'startup_reads': len(early), 'total_reads': len(reads),
            'startup_elapsed_ps': end-start, 'startup_read_outstanding_union_ps': union,
            'startup_first_r_latency_ps': {'min': min(latencies), 'median': statistics.median(latencies), 'max': max(latencies)},
            'reads': reads, 'limitations': ['AXI request-to-response timing is not pure DRAM timing.',
                                           'Outstanding-interval union is not a CPU-stall measurement.',
                                           'No equivalent hardware bus trace; cannot assign hardware gap from this alone.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    result = inspect(a.log)
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'reads'}, indent=2))
