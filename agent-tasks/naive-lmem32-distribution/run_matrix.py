#!/usr/bin/env python3
"""Configure isolated builds and run the frozen LMEM topology matrix serially."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
TOPOLOGIES = ['p16_b16', 'p32_b16', 'p16_b32', 'p32_b32']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iteration', default='v1')
    parser.add_argument('--topologies', nargs='+', choices=TOPOLOGIES, default=TOPOLOGIES)
    args = parser.parse_args()
    for topology in args.topologies:
        build = ROOT / f'build_naive_lmem32_{topology}_vcs'
        build.mkdir(exist_ok=True)
        logs = TASK / 'runs' / args.iteration / topology
        logs.mkdir(parents=True, exist_ok=True)
        config = TASK / 'configs' / f'{topology}.sh'
        raw = subprocess.check_output(['bash', '-c', 'set -e; source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
        env = dict(v.split('=', 1) for v in raw.decode().split('\0') if '=' in v)
        with (logs / 'configure.log').open('w') as log:
            subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex', f'--prefix={Path.home()}/tools/vortex'], cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        for case in ['m4', 'm256']:
            result_path = logs / case / 'result.json'
            if result_path.exists():
                result = json.loads(result_path.read_text())
                if result['passed']:
                    print(f'Reusing completed {topology} {case}', flush=True)
                    continue
                raise RuntimeError(f'Existing failed evidence; use a new iteration: {result_path}')
            cmd = [sys.executable, str(TASK / 'verify.py'), '--topology', topology, '--case', case, '--iteration', args.iteration]
            if case == 'm4':
                cmd.append('--rebuild')
            print(f'{datetime.now().isoformat()} Running {topology} {case}', flush=True)
            completed = subprocess.run(cmd, cwd=ROOT)
            status = dict(updated=datetime.now().isoformat(), topology=topology, case=case, returncode=completed.returncode)
            (TASK / 'verification-progress.json').write_text(json.dumps(status, indent=2) + '\n')
            if completed.returncode:
                return completed.returncode
    return 0


if __name__ == '__main__':
    sys.exit(main())
