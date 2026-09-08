#!/usr/bin/env python3
"""Validate one controller invocation; integrate outstanding-count intervals."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

PATTERN = re.compile(r'REFERENCE_WORK t=(\d+) start=([01]) done=([01]) active=([01]) output=([01]) issue=([01]{6}) retire=([01]{6}) busy=([01]{6}) queued=([01]{6})$')
NAMES = ('input_read', 'weight', 'scale', 'zero_point', 'output', 'dma')

def inspect(path):
    rows = []
    with path.open() as stream:
        for line in stream:
            if 'REFERENCE_WORK' not in line:
                continue
            match = PATTERN.fullmatch(line.strip())
            if not match:
                raise ValueError('Malformed/unknown-valued event')
            values = match.groups()
            rows.append([int(v, 2) if i >= 5 else int(v) for i, v in enumerate(values)])
    if not rows or len(rows) >= 16384:
        raise ValueError('Missing or potentially capped trace')
    if sum(r[1] for r in rows) != 1 or sum(r[2] for r in rows) != 1 or not rows[0][1] or not rows[-1][2]:
        raise ValueError('Expected exactly one complete invocation')
    pending = [0]*6
    issued, retired, peaks = [0]*6, [0]*6, [0]*6
    masks = Counter()
    previous = rows[0][0]
    for t, start, done, active, output, issue, retire, busy, queued in rows:
        if t < previous or (t-previous) % 10000:
            raise ValueError('Nonmonotonic or non-100MHz event')
        mask = sum((int(n > 0) << i) for i, n in enumerate(pending))
        masks[mask] += t-previous
        if busy != mask:
            raise ValueError(f'Observed inflight mask disagrees with event counts at {t}: {busy} != {mask}')
        for i in range(6):
            inc, dec = (issue >> i) & 1, (retire >> i) & 1
            issued[i] += inc
            retired[i] += dec
            pending[i] += inc-dec
            if pending[i] < 0:
                raise ValueError('Unmatched retire')
            peaks[i] = max(peaks[i], pending[i])
        previous = t
    if any(pending) or issued != retired:
        raise ValueError('Outstanding work remains at done')
    duration = rows[-1][0]-rows[0][0]
    if sum(masks.values()) != duration:
        raise ValueError('Interval accounting mismatch')
    return {
        'log': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'events': len(rows), 'start_ps': rows[0][0], 'done_ps': rows[-1][0],
        'duration_cycles': duration//10000,
        'output_store_events': sum(r[4] for r in rows),
        'children': {name: {'issued': issued[i], 'retired': retired[i],
            'max_outstanding': peaks[i],
            'outstanding_union_cycles': sum(v for k, v in masks.items() if k & (1 << i))//10000}
            for i, name in enumerate(NAMES)},
        'mask_cycles': {f'{k:06b}': v//10000 for k, v in sorted(masks.items())},
        'dma_and_input_overlap_cycles': sum(v for k, v in masks.items() if k & 32 and k & 1)//10000,
        'limitations': ['Controller outstanding time, not HBM or CPU stall time.',
                       'No FIFO transaction pairing or per-command latency claim.',
                       'DMA prepare/prefetch activity may precede logical issue.',
                       'No corresponding hardware internal trace.']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.log)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps({k: result[k] for k in ('duration_cycles', 'children', 'dma_and_input_overlap_cycles')}, indent=2))
