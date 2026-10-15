#!/usr/bin/env python3
"""Run ordered blackbox cases in one isolated configured build, stopping on failure."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--iteration', type=int, required=True)
parser.add_argument('--cases', required=True, help='JSON object mapping case names to app arguments')
parser.add_argument('--app', default='fpint_gemm_ffn_hw_naive')
parser.add_argument('--timeout', type=int, default=300)
parser.add_argument('--output-dir', type=Path, default=Path(__file__).parent)
args = parser.parse_args()
build = args.build.resolve()
repo = Path(__file__).resolve().parents[3]
cases = json.loads(args.cases)
for name, app_args in cases.items():
    logfile = build / f'{name}.iter{args.iteration}.log'
    command = ['bash', '-c',
        'source ./config.sh; '
        'export MAKEFLAGS="-j4 XILINX_IP_DIR=$PWD/../build_fpfp_baseline/sim/xrtsim_vcs/xilinx_ip"; '
        'exec "$@"', 'bash',
        'timeout', '--signal=TERM', '--kill-after=20s', str(args.timeout),
        './ci/run_black.sh', 'xrt-vcs-sim', '--app', args.app,
        '--args', app_args, '--configs-extra', f'-DFPFP_VERIFY_ITERATION={args.iteration}', '--perf', '3']
    print(f'Running {build.name}/{name}: {app_args}', flush=True)
    start = time.monotonic()
    with logfile.open('w') as log:
        result = subprocess.run(command, cwd=build, stdout=log, stderr=subprocess.STDOUT)
    elapsed = time.monotonic() - start
    report = args.output_dir.resolve() / f'{build.name}_{name}_iter{args.iteration}.json'
    classified = subprocess.run([sys.executable, str(Path(__file__).with_name('record_blackbox.py')),
        '--log', str(logfile), '--output', str(report), '--name', f'{build.name}/{name}',
        '--returncode', str(result.returncode), '--iteration', str(args.iteration)])
    record = json.loads(report.read_text())
    record['elapsed_seconds'] = elapsed
    report.write_text(json.dumps(record, indent=2) + '\n')
    simlog = build / 'sim/xrtsim_vcs/simv.log'
    if simlog.exists():
        saved = simlog.with_name(f'simv_{name}_iter{args.iteration}.log')
        shutil.copyfile(simlog, saved)
    if classified.returncode:
        raise SystemExit(classified.returncode)
