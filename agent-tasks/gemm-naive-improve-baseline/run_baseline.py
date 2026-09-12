#!/usr/bin/env python3
"""Run one corrected-vector VCS measurement with immutable run provenance."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def hashes(app=None):
    paths = subprocess.check_output(
        ['rg', '--files', 'hw/rtl', 'configs', 'sim/xrtsim_vcs',
         'tests/regression/fpint_gemm_ffn_hw',
         'tests/regression/fpint_gemm_ffn_hw_naive', 'tests/common'],
        cwd=ROOT, text=True).splitlines()
    if app:
        paths += subprocess.check_output(
            ['rg', '--files', f'tests/regression/{app}'], cwd=ROOT,
            text=True).splitlines()
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
            for p in sorted(paths) if (ROOT / p).is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backend', choices=['naive', 'improve'])
    parser.add_argument('--m', type=int, required=True)
    parser.add_argument('--k', type=int, default=512)
    parser.add_argument('--n', type=int, default=512)
    parser.add_argument('--qdir', type=int, choices=[0, 1], default=0)
    parser.add_argument('--wtrans', type=int, choices=[0, 1], default=0)
    parser.add_argument('--tagged', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--build', type=Path, help='Existing configured build override')
    parser.add_argument('--config', type=Path, help='Repository-relative sourced config override')
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--app', help='Regression app override')
    parser.add_argument('--app-args', help='Exact arguments for an app override')
    parser.add_argument('--ucli-file', type=Path, help='Directed simulation stimulus; copied and hashed in run evidence')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    build = (args.build.resolve() if args.build else
             ROOT / f'build_fpint_latency_{args.backend}_vcs')
    if not (build / 'config.mk').is_file():
        raise RuntimeError(f'Configure the build directory first: {build}')
    config = (args.config.resolve() if args.config else
              ROOT / 'agent-tasks/fpint-gemm-latency-compare' / f'{args.backend}.sh')
    raw = subprocess.check_output(
        ['bash', '-c', 'set -e; source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
    env = dict(v.split('=', 1) for v in raw.decode().split('\0') if '=' in v)
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'FPGA_BIN_DIR',
                'XRT_XCLBIN_PATH']:
        env.pop(key, None)
    env.update(CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0', FSDB_DUMP='1',
               PATH='/usr/bin:' + env['PATH'],
               VCS_SIMV_FLAGS=f'+fsdb_file={out}/wave.fsdb')
    stimulus = None
    if args.ucli_file:
        stimulus_path = out / 'stimulus.tcl'
        stimulus_path.write_bytes(args.ucli_file.read_bytes())
        if any(c.isspace() for c in str(stimulus_path)):
            raise ValueError('The existing blackbox simv flag parser requires a whitespace-free stimulus path')
        env['VCS_SIMV_FLAGS'] += f' -ucli -do {stimulus_path}'
        # Command-line make assignment overrides the legacy two-step typo
        # -debug_access=all only for directed UCLI runs.
        env['MAKEFLAGS'] = (env.get('MAKEFLAGS', '') + ' VCS_P2_FLAGS=-debug_access+all').strip()
        stimulus = dict(path=str(stimulus_path), sha256=hashlib.sha256(stimulus_path.read_bytes()).hexdigest())
    env['CONFIGS'] += ' -DGEMM_LATENCY_OBSERVER'
    app = args.app or ('fpint_gemm_ffn_hw' + ('_naive' if args.backend == 'naive' else ''))
    app_args = (f'-m {args.m} -k {args.k} -n {args.n} -q 32 '
                f'-t {args.wtrans} -d {args.qdir} -r {args.repeat}')
    if args.tagged:
        app_args += ' --tagged'
    if args.app_args is not None:
        app_args = args.app_args
    command = ['timeout', '--signal=TERM', '--kill-after=30', str(args.timeout),
               'ci/run_black.sh', 'xrt-vcs-sim', '--perf', '3', '--app', app,
               '--args', app_args]
    before = hashes(args.app)
    manifest = dict(backend=args.backend, m=args.m, k=args.k, n=args.n,
                    app=app, app_args=app_args, directed_stimulus=stimulus, simv_flags=env['VCS_SIMV_FLAGS'], makeflags=env.get('MAKEFLAGS',''),
                    workload_parameters_source='app implementation' if args.app else 'runner arguments',
                    qdir=args.qdir, wtrans=args.wtrans, tagged=args.tagged,
                    repeat=args.repeat, command=command, configs=env['CONFIGS'],
                    start=datetime.now().isoformat(), build=str(build), config=str(config),
                    git_head=subprocess.check_output(
                        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    source_hashes=before, pid=os.getpid(), state='running')
    manifest_path = out / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    simv = build / 'sim/xrtsim_vcs/simv'
    if args.rebuild and simv.exists():
        # Preserve the executable; do not delete existing simulation artifacts.
        saved = simv.with_name('simv_before_rev3_' + datetime.now().strftime('%Y%m%d_%H%M%S'))
        if saved.exists():
            raise RuntimeError(f'Refusing to overwrite {saved}')
        simv.rename(saved)
        manifest['preserved_simv'] = str(saved)
    with (out / 'wrapper.log').open('w') as log:
        child = subprocess.Popen(command, cwd=build, env=env, stdout=log,
                                 stderr=subprocess.STDOUT)
        manifest['child_pid'] = child.pid
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        rc = child.wait()
    for name in ['simv.log', 'u55c_model_manifest.json']:
        source = build / 'sim/xrtsim_vcs' / name
        if source.exists():
            shutil.copy2(source, out / name)
    log_text = (out / 'wrapper.log').read_text(errors='replace')
    after = hashes(args.app)
    changed = sorted(p for p in before.keys() | after.keys()
                     if before.get(p) != after.get(p))
    manifest.update(returncode=rc, state='finished', end=datetime.now().isoformat(),
                    passed=rc == 0 and bool(re.search(r'^(?:PASSED|TEST PASSED(?::[^\n]*)?)$', log_text, re.M)),
                    source_changes_during_run=changed,
                    perf=[s for s in log_text.splitlines() if s.startswith('PERF:')])
    # Numerical success alone is not a frozen baseline: FSDB matching, faults,
    # delivery-delay tests, and hardware preservation are separate P0 gates.
    manifest['baseline_frozen'] = False
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: manifest[k] for k in
                      ['returncode', 'passed', 'source_changes_during_run', 'perf']}))
    return 0 if manifest['passed'] and not changed else 1


if __name__ == '__main__':
    sys.exit(main())
