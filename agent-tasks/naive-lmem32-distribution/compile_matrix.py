#!/usr/bin/env python3
"""Compile MXU32 legacy/distributed topologies without running simulation."""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iteration', default='v1')
    args = parser.parse_args()
    verification = module('verify_rtl', ROOT / 'tools/verify_rtl.py')
    runner = module('baseline_runner', ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py')
    for width in [32, 64]:
        name = f'mxu32_p{width}_b{width}'
        out = TASK / 'compile' / args.iteration / name
        out.mkdir(parents=True, exist_ok=False)
        build = ROOT / f'build_naive_lmem32_{name}_vcs'
        build.mkdir(exist_ok=True)
        base = ROOT / 'configs/naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh'
        config = out / 'config.sh'
        config.write_text(base.read_text().replace('-DLMEM_NUM_PORTS=32', f'-DLMEM_NUM_PORTS={width}').replace('-DLMEM_NUM_BANKS=32', f'-DLMEM_NUM_BANKS={width}'))
        raw = subprocess.check_output(['bash', '-c', 'set -e; source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
        env = dict(v.split('=', 1) for v in raw.decode().split('\0') if '=' in v)
        for key in ['DEBUG', 'PERF', 'SCOPE', 'FSDB_DUMP']:
            env.pop(key, None)
        env.update(CC='/usr/bin/gcc', CXX='/usr/bin/g++', PATH='/usr/bin:' + env['PATH'])
        before = runner.hashes()
        start = datetime.now().isoformat()
        with (out / 'configure.log').open('w') as log:
            subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex', f'--prefix={Path.home()}/tools/vortex'], cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            subprocess.run(['make', '-C', 'hw', 'config'], cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        simv = build / 'sim/xrtsim_vcs/simv'
        if simv.exists():
            simv.rename(simv.with_name('simv_preserved_' + datetime.now().strftime('%Y%m%d_%H%M%S')))
        cmd = ['timeout', '--signal=TERM', '--kill-after=30', '7200', 'make', '-C', 'sim/xrtsim_vcs', 'simv']
        print(f'{start} Compiling {name}', flush=True)
        with (out / 'compile.log').open('w') as log:
            run = subprocess.run(cmd, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT)
        text = (out / 'compile.log').read_text(errors='replace')
        after = runner.hashes()
        changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
        result = dict(name=name, command=cmd, start=start, end=datetime.now().isoformat(), returncode=run.returncode,
                      configs=env['CONFIGS'], source_hashes=before, source_changes=changed,
                      strict_failure=verification.has_strict_failure(text), simv_exists=simv.exists(), simulation_executed=False)
        result['passed'] = run.returncode == 0 and not result['strict_failure'] and simv.exists() and not changed
        if not result['passed']:
            result['error_excerpt'] = verification.extract_errors(text)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({key: result[key] for key in ['name', 'returncode', 'passed', 'source_changes']}), flush=True)
        if not result['passed']:
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
