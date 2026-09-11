#!/usr/bin/env python3
"""Check durable device lifecycle order and independent FSDB job identity."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def verify(run):
    manifest = json.loads((run / 'manifest.json').read_text())
    endpoints = json.loads((run / 'endpoints/latency.json').read_text())
    log = (run / 'wrapper.log').read_text()
    assert manifest['state'] == 'finished'
    assert manifest['returncode'] == 0 and manifest['passed']
    assert manifest['source_changes_during_run'] == []
    assert manifest['app'] == 'fpint_gemm_lifecycle'
    assert log.count('LIFECYCLE_SINGLE_START jobs=3 ') == 1
    assert re.search(r'^TEST PASSED:', log, re.M)
    records = re.findall(
        r'^LIFECYCLE_(START|VERIFIED) job=(\d+) device_cycle=(\d+)$', log, re.M)
    expected = [(event, str(job)) for job in range(3)
                for event in ('START', 'VERIFIED')]
    assert [(event, job) for event, job, cycle in records] == expected
    cycles = [int(cycle) for event, job, cycle in records]
    assert cycles[0] > 0 and all(a < b for a, b in zip(cycles, cycles[1:]))
    assert endpoints['backend'] == manifest['backend']
    assert Path(endpoints['wave']).resolve() == (run / 'wave.fsdb').resolve()
    assert endpoints['log_match'] is True and endpoints['differences'] == []
    jobs = endpoints['jobs']
    assert len(jobs) == 3 and [j['job'] for j in jobs] == [0, 1, 2]
    assert len({j['epoch'] for j in jobs}) == 1
    assert all(a['e_hs'] < b['e_cfg'] for a, b in zip(jobs, jobs[1:]))
    evidence = ['manifest.json', 'wrapper.log', 'simv.log',
                'endpoints/latency.json', 'endpoints/reset.csv']
    return dict(status='pass', backend=manifest['backend'],
                run=str(run.resolve()), device_cycles=cycles,
                epoch=jobs[0]['epoch'], jobs=jobs,
                workload=dict(M=3, K=64, N=64, QBLK=32, QDIR=0, WTRANS=0,
                              tagged=True, generations=[0, 1, 2], vx_starts=1),
                scope='Device verification before each next job; same-epoch controller invocations; host recheck of all outputs',
                limitations='MCYCLE and observer edge indices are distinct clocks/counter origins and are not directly subtracted. This is not active-reset, arbitrary-stall, or large-shape proof.',
                evidence_sha256={name: hashlib.sha256((run / name).read_bytes()).hexdigest()
                                 for name in evidence})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.run)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('status', 'backend', 'device_cycles', 'epoch')}))
