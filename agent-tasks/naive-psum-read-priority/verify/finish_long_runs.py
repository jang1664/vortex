#!/usr/bin/env python3
"""Finish the frozen v2 M256 sweep with at most two concurrent simulations."""
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
VERIFY = Path(__file__).resolve().parent
RUNS = VERIFY.parent / 'runs' / 'v2'
active = {1: None, 2: None}
queued = [4, 8]
failed = False

while active:
    for quota in list(active):
        path = RUNS / f'r{quota}-m256' / 'result.json'
        if not path.exists():
            continue
        try:
            result = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        process = active.pop(quota)
        if process is not None:
            process.wait()
        print(json.dumps({k: result[k] for k in
                          ['read_quota', 'passed', 'gemm_cycles', 'core_cycles',
                           'source_changes', 'config_unchanged', 'log_dir']}), flush=True)
        if not result['passed']:
            failed = True
        if queued and not failed:
            next_quota = queued.pop(0)
            cmd = [sys.executable, str(VERIFY / 'run.py'), '--r', str(next_quota),
                   '--config', str(VERIFY / f'r{next_quota}.sh'), '--case', 'm256',
                   '--iteration', 'v2']
            active[next_quota] = subprocess.Popen(cmd, cwd=ROOT)
    if active:
        time.sleep(5)
sys.exit(1 if failed else 0)
