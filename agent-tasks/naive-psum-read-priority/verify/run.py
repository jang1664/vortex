#!/usr/bin/env python3
"""Run one frozen PSUM scheduling candidate through the VCS blackbox wrapper."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
TASK = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--r', type=int, choices=[1, 2, 4, 8], required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--case', choices=['m4', 'm256', 'short4', 'short16'], required=True)
    parser.add_argument('--iteration', default='v1')
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--timeout', type=int, default=7200)
    args = parser.parse_args()
    m, k, n = {'m4': (4, 512, 512), 'm256': (256, 512, 512),
               'short4': (4, 64, 16), 'short16': (16, 64, 16)}[args.case]
    build = ROOT / f'build_psum_priority_r{args.r}_vcs'
    config = args.config.resolve()
    out = TASK / 'runs' / args.iteration / f'r{args.r}-{args.case}'
    if out.exists():
        parser.error(f'Refusing to overwrite existing evidence: {out}')
    config_hash = hashlib.sha256(config.read_bytes()).hexdigest()
    cmd = [sys.executable, str(RUNNER), 'naive', '--m', str(m), '--k', str(k),
           '--n', str(n), '--qdir', '0', '--wtrans', '0', '--repeat', '1',
           '--timeout', str(args.timeout), '--build', str(build), '--output', str(out),
           '--config', str(config)]
    if args.rebuild:
        cmd.append('--rebuild')
    print(f'Starting R{args.r} {args.case}: {out}', flush=True)
    run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'runner.log').write_text(run.stdout + run.stderr)
    if not (out / 'manifest.json').exists():
        print(run.stdout + run.stderr, flush=True)
        return 1
    manifest = json.loads((out / 'manifest.json').read_text())
    wrapper = (out / 'wrapper.log').read_text(errors='replace')
    simv = (out / 'simv.log').read_text(errors='replace') if (out / 'simv.log').exists() else ''
    combined = wrapper + '\n' + simv
    spec = importlib.util.spec_from_file_location('verify_rtl', ROOT / 'tools/verify_rtl.py')
    verify = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verify)
    done = [s for s in simv.splitlines() if s.startswith('GEMM_LATENCY_DONE ')]
    gemm = [int(re.search(r'\bL_gemm=(\d+)', s)[1]) for s in done]
    core = [int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),', wrapper, re.M)]
    wave = out / 'wave.fsdb'
    result = dict(read_quota=args.r, case=args.case, m=m, k=k, n=n,
                  runner_returncode=run.returncode, wrapper_returncode=manifest.get('returncode'),
                  tool_pass=verify.check_pass(combined), strict_failure=verify.has_strict_failure(combined),
                  source_changes=manifest.get('source_changes_during_run'),
                  config_sha256=config_hash,
                  config_unchanged=config_hash == hashlib.sha256(config.read_bytes()).hexdigest(),
                  gemm_cycles=gemm, core_cycles=core, observer_done=done,
                  fsdb_bytes=wave.stat().st_size if wave.exists() else 0,
                  log_dir=str(out.relative_to(ROOT)), perf=manifest.get('perf', []))
    result['passed'] = (run.returncode == 0 and result['wrapper_returncode'] == 0
                        and result['tool_pass'] and not result['strict_failure']
                        and result['source_changes'] == [] and result['config_unchanged']
                        and len(gemm) == 1 and len(core) == 1 and result['fsdb_bytes'] > 0)
    if not result['passed']:
        result['error_excerpt'] = verify.extract_errors(combined)
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
