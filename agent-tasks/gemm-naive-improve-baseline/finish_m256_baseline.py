#!/usr/bin/env python3
"""Wait for the existing capture, then verify endpoints and derive numeric gates."""
import json
from pathlib import Path
import subprocess
import sys
import time

TASK = Path(__file__).resolve().parent
RUN = TASK / 'p0-baseline/naive-m256-retry1'


def main():
    deadline = time.monotonic() + 7500
    while time.monotonic() < deadline:
        try:
            manifest = json.loads((RUN / 'manifest.json').read_text())
        except json.JSONDecodeError:
            time.sleep(5)
            continue
        if manifest['state'] == 'finished':
            break
        time.sleep(5)
    else:
        raise TimeoutError('Existing capture has not published terminal status; no restart attempted')
    if not manifest['passed'] or manifest['returncode'] != 0 or manifest['source_changes_during_run']:
        raise RuntimeError('Existing capture did not produce a source-stable numerical PASS')
    subprocess.run([sys.executable, str(TASK / 'extract_latency.py'), 'naive',
                    str(RUN / 'wave.fsdb'), '--log', str(RUN / 'simv.log'),
                    '--output', str(RUN / 'endpoints')], check=True)
    subprocess.run([sys.executable, str(TASK / 'p0-gates.py'),
                    '--naive-m256', str(RUN),
                    '--output', str(TASK / 'p0-numeric-gates.json')], check=True)
    print('M256 numerical/endpoint checks and numeric gate derivation complete; full P0 review remains required', flush=True)


if __name__ == '__main__':
    main()
