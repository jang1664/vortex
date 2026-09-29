#!/usr/bin/env python3
"""Exercise each distinct fabric/ordering choice with the LMEM scoreboard."""
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / 'build_omega_ordering_macros'
LOGS = HERE / 'logs'
LOGS.mkdir(exist_ok=True)
base = subprocess.check_output(['bash', '-c',
    'source "$1"; printf "%s" "$CONFIGS"', 'config',
    str(ROOT / 'configs/naive_gemm_th32_tcol32_hwexp_dcache.sh')], text=True)
base = [t for t in shlex.split(base) if t not in
        ('-DLMEM_REQ_OMEGA_ENABLE', '-DLMEM_RSP_OMEGA_ENABLE')]


def verify(case):
    rq, rs, dq, ds = case
    name = f'omega_rq{rq}_rs{rs}_dq{dq}_ds{ds}'
    dest = BUILD / 'hw/unittest' / name
    dest.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'hw/unittest/local_mem_top/Makefile', dest / 'Makefile')
    flags = base + ['-DXLEN_64']
    flags += ['-D' + k for k, v in (
        ('LMEM_REQ_OMEGA_ENABLE', rq), ('LMEM_RSP_OMEGA_ENABLE', rs),
        ('LMEM_REQ_OMEGA_ORDER_DISABLE', dq), ('LMEM_RSP_OMEGA_ORDER_DISABLE', ds)) if v]
    env = os.environ.copy()
    env.pop('MAKEFLAGS', None)
    env.update(CONFIGS=' '.join(flags), CC='/usr/bin/gcc', CXX='/usr/bin/g++', THREADS='4')
    cmd = ['python3', str(ROOT / 'tools/verify_rtl.py'), 'unittest', '--path', str(dest), '--sim', 'vlt']
    print('START', name, flush=True)
    with (LOGS / (name + '.json')).open('w') as log:
        rc = subprocess.call(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    print('END', name, rc, flush=True)
    return dict(name=name, passed=rc == 0, returncode=rc, command=cmd, configs=env['CONFIGS'])


if __name__ == '__main__':
    # Both-on default first, then independent bypass and mixed fabric choices.
    cases = [(1, 1, 0, 0), (1, 1, 1, 0), (1, 1, 0, 1), (1, 1, 1, 1),
             (1, 0, 0, 0), (1, 0, 1, 0), (0, 1, 0, 0), (0, 1, 0, 1), (0, 0, 1, 1)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(verify, cases))
    (HERE / 'unit_results.json').write_text(json.dumps(results, indent=2) + '\n')
    assert all(r['passed'] for r in results), 'Inspect failed case logs'
    print('PASS: all nine fabric/ordering modes', flush=True)
