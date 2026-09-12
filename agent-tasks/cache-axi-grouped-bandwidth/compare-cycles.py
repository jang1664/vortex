#!/usr/bin/env python3
"""Produce cycle tables from explicitly selected successful wrapper runs.

Usage: compare-cycles.py manifest.json
Manifest: list of {case, baseline, k1, k2}, each run path a directory containing
wrapper.log and exit.txt. Never selects a run implicitly or hides a missing case.
"""
import json
from pathlib import Path
import re
import sys


def read_run(path):
    run = Path(path)
    if (run / 'exit.txt').read_text().strip() != '0':
        raise ValueError(f'{run}: nonzero exit')
    log = (run / 'wrapper.log').read_text()
    if not re.search(r'^PASSED!?\s*$', log, re.M):
        raise ValueError(f'{run}: missing numerical PASS')
    if re.search(r'^\s*(Fatal:|FAILED|Error-)', log, re.M):
        raise ValueError(f'{run}: failure diagnostic')
    simlog = run / 'simv.log'
    if not simlog.exists():
        raise ValueError(f'{run}: missing archived simulation log')
    if re.search(r'^\s*(Fatal:|Error:)', simlog.read_text(), re.M):
        raise ValueError(f'{run}: simulation assertion failure')
    total = re.findall(r'^PERF: instrs=\d+, cycles=(\d+), IPC=', log, re.M)
    node = re.findall(r'^PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=', log, re.M)
    # Softmax dumps counters explicitly and again during device close. Accept
    # identical snapshots, but never combine different invocations silently.
    if len(set(total)) != 1 or len(set(node)) > 1:
        raise ValueError(f'{run}: ambiguous/missing cycle summary')
    return {'total': int(total[-1]),
            'node': int(node[-1][1]) if node else None,
            'jobs': int(node[-1][0]) if node else None}


def delta(current, reference):
    if not reference:
        raise ValueError('zero reference cycles')
    return f'{current-reference:+d} ({100*(current-reference)/reference:+.2f}%)'


def main():
    records = json.loads(Path(sys.argv[1]).read_text())
    if len(records) != 6 or len({r['case'] for r in records}) != 6:
        raise ValueError('Manifest must select all six distinct required cases')
    rows = []
    for record in records:
        runs = [read_run(record[key]) for key in ('baseline', 'k1', 'k2')]
        metrics = ('total', 'node') if 'fpint' in record['case'].lower() else ('total',)
        if 'node' in metrics and len({r['jobs'] for r in runs}) != 1:
            raise ValueError(f"{record['case']}: unmatched raw jobs field")
        for metric in metrics:
            b, k1, k2 = (r[metric] for r in runs)
            if None in (b, k1, k2):
                raise ValueError(f"{record['case']}: missing {metric}")
            rows.append(f"| {record['case']} | {metric} | {b} | {k1} | {k2} | {delta(k2,b)} | {delta(k2,k1)} |")
    print('| Case | Cycle metric | Baseline | K1 | K2 | K2 vs baseline | K2 vs K1 |')
    print('| --- | --- | ---: | ---: | ---: | --- | --- |')
    print('\n'.join(rows))


if __name__ == '__main__':
    main()
