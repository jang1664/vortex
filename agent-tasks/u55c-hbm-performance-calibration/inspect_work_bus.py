#!/usr/bin/env python3
"""Pair reads in controller invocation window; no hardware-stall attribution."""
import argparse
from collections import Counter, defaultdict, deque
import json
from pathlib import Path
import re
import statistics
from inspect_work_trace import inspect as inspect_work

def inspect(path):
    work = inspect_work(path)
    begin, end = work['start_ps'], work['done_ps']
    pending, completed = defaultdict(deque), []
    with path.open() as stream:
        for line in stream:
            if 'Fatal:' in line:
                raise ValueError('Fatal in trace')
            if 'STARTUP_AR ' in line:
                match = re.fullmatch(r'STARTUP_AR t=(\d+) port=(\d+) id=([0-9a-f]+) addr=([0-9a-f]+) len=([0-9a-f]+)\s*', line, re.I)
                if not match:
                    raise ValueError('Malformed/unknown AR')
                t, p, ident, addr, length = match.groups()
                pending[(int(p), int(ident,16))].append(dict(ar_ps=int(t), port=int(p),
                    address=int(addr,16), beats=int(length,16)+1, responses=[]))
            elif 'STARTUP_R ' in line:
                match = re.fullmatch(r'STARTUP_R t=(\d+) port=(\d+) id=([0-9a-f]+) last=([01])\s*', line, re.I)
                if not match:
                    raise ValueError('Malformed/unknown R')
                t, p, ident, last = match.groups()
                queue = pending[(int(p), int(ident,16))]
                if not queue:
                    raise ValueError('Response without AR')
                request = queue[0]
                t = int(t)
                if t < request['ar_ps'] or (request['responses'] and t < request['responses'][-1]):
                    raise ValueError('Response time reversal')
                request['responses'].append(t)
                if int(last) != (len(request['responses']) == request['beats']):
                    raise ValueError('RLAST/length mismatch')
                if last == '1':
                    completed.append(queue.popleft())
    if any(pending.values()):
        raise ValueError('Incomplete read trace')
    inside = [r for r in completed if begin <= r['ar_ps'] < end]
    if not inside:
        raise ValueError('No invocation reads')
    latencies = [r['responses'][0]-r['ar_ps'] for r in inside]
    response_beats = Counter()
    intervals = []
    for r in completed:
        response_beats[r['port']] += sum(begin <= t < end for t in r['responses'])
        left, right = max(begin,r['ar_ps']), min(end,r['responses'][-1])
        if right > left:
            intervals.append((left,right))
    union, rightmost = 0, begin
    for left, right in sorted(intervals):
        union += max(0,right-max(left,rightmost))
        rightmost = max(rightmost,right)
    return {'controller': work, 'total_reads': len(completed),
        'invocation_ar_count': len(inside),
        'invocation_ar_by_port': dict(Counter(r['port'] for r in inside)),
        'invocation_r_beats_by_port': dict(response_beats),
        'arlen_beats_histogram': dict(Counter(r['beats'] for r in inside)),
        'first_r_latency_ps': {'min': min(latencies), 'median': statistics.median(latencies), 'max': max(latencies)},
        'outstanding_read_union_ps': union,
        'reads': completed,
        'limitations': ['Read channels only; beat count is not byte count without interface size.',
                       'Reads include any core traffic overlapping the invocation.',
                       'Read-outstanding union is not stall time; intervals can overlap compute.',
                       'No hardware AXI trace; cannot attribute hardware gap directly.']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.log)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('reads','controller')}, indent=2))
