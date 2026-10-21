#!/usr/bin/env python3
"""Summarize pre-edge GEMM trace observations; concurrent stages are not additive."""
import argparse
from collections import Counter, defaultdict
import csv
import json
from pathlib import Path
import re

DMA_STATES = ['idle', 'decode', 'allocate_request', 'allocate_response', 'allocate_gap',
              'program', 'kick', 'poll_gap', 'poll_request', 'poll_response', 'done',
              'output_start', 'output_wait', 'output_drain']
TENSORS = ['input', 'weight', 'output', 'scale', 'zero', 'invalid']
CHILDREN = ['input', 'weight', 'scale', 'zero', 'dma']


def summarize(trace, log):
    exclusive, dma_states, dma_tensors, events = Counter(), Counter(), Counter(), Counter()
    children = {name: Counter() for name in CHILDREN}
    executor_active = Counter()
    tensor_states = defaultdict(Counter)
    descriptors = []
    pending = None
    count = 0
    for raw in csv.DictReader(trace.open()):
        row = {k: int(v, 16 if k == 'dma_base' else 10) for k, v in raw.items()}
        count += 1
        dma = not bool(row['executor_idle'] & 8)
        pipe = not bool(row['pipeline_empty'])
        exclusive['dma_and_pipeline' if dma and pipe else 'dma_only' if dma else
                  'pipeline_only' if pipe else 'neither'] += 1
        dma_states[DMA_STATES[row['dma_state']]] += 1
        if dma:
            tensor = TENSORS[row['tensor']]
            dma_tensors[tensor] += 1
            tensor_states[tensor][DMA_STATES[row['dma_state']]] += 1
        for i, name in enumerate(['input', 'weight', 'quant', 'dma']):
            executor_active[name] += not bool(row['executor_idle'] >> i & 1)
        for name in ['input_fire', 'acc_write_fire']:
            events[name] += row[name]
        events['input_backpressure'] += bool(row['input_valid'] and not row['input_ready'])
        for i, name in enumerate(CHILDREN):
            def bit(field):
                return bool(row[field] >> i & 1)
            if bit('queue_empty'):
                category = 'queue_empty'
            elif not bit('deps_ready'):
                category = 'dependency_wait'
            elif bit('inflight_full'):
                category = 'inflight_full'
            elif bit('prepare_offered'):
                category = 'preparing'
            elif not bit('cmd_ready'):
                category = 'executor_backpressure'
            elif bit('issue_fire'):
                category = 'issue'
            else:
                category = 'other'
            children[name][category] += 1
        if row['dma_state'] == 1:
            assert pending is None
            pending = {'tensor': TENSORS[row['tensor']], 'base': hex(row['dma_base']),
                       'work_seq': row['dma_work_seq'], 'begin_cycle': row['cycle']}
        if row['dma_state'] == 10 and pending is not None:
            pending['cycles'] = row['cycle'] - pending['begin_cycle'] + 1
            descriptors.append(pending)
            pending = None
    text = log.read_text()
    core_cycles = int(re.search(r'PERF: instrs=\d+, cycles=(\d+)', text)[1])
    job_cycles = int(re.search(r'PERF: jobs=\d+ total_cycles=(\d+)', text)[1])
    assert count == job_cycles, (count, job_cycles)
    assert sum(exclusive.values()) == count
    assert all(sum(c.values()) == count for c in children.values())
    assert pending is None
    assert 'PASSED' in text
    return dict(trace=str(trace.resolve()), log=str(log.resolve()), core_cycles=core_cycles,
                gemm_job_cycles=count, outside_gemm_job_cycles=core_cycles-count,
                exclusive_cycles=exclusive, dma_states=dma_states, dma_tensors=dma_tensors,
                dma_tensor_states=tensor_states, executor_active_cycles=executor_active,
                events=events, child_wait_cycles=children, descriptors=descriptors)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = summarize(args.trace, args.log)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['core_cycles', 'gemm_job_cycles',
          'outside_gemm_job_cycles', 'exclusive_cycles', 'dma_tensors', 'events']}))
