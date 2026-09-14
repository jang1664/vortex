#!/usr/bin/env python3
"""Run ACC selection comparisons through the existing frozen VCS runner."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
RUNNER = ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py'
spec = importlib.util.spec_from_file_location('verify_rtl', ROOT / 'tools/verify_rtl.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
CASES = {
    'm4': (4, 512, 512, 0, 0),
    'm256': (256, 512, 512, 0, 0),
    'm1': (1, 128, 128, 0, 0),
    'm3_tail': (3, 256, 160, 0, 0),
    'n150': (3, 128, 150, 0, 0),
    'qrow': (4, 128, 128, 1, 0),
    'transpose': (4, 128, 128, 0, 1),
    'qrow_transpose': (4, 128, 128, 1, 1),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['off', 'on', 'improve'])
    parser.add_argument('--cases', nargs='+', choices=CASES, default=['m4', 'm256'])
    parser.add_argument('--label', help='Separate evidence directory, e.g. a diagnostic iteration')
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--ucli-file', type=Path)
    parser.add_argument('--build', type=Path, help='Separate configured build for independent cases')
    args = parser.parse_args()
    build = args.build.resolve() if args.build else ROOT / f'build_naive_acc_{args.mode}_vcs'
    assert (build / 'config.mk').is_file(), 'Source config and configure build first'
    for index, case in enumerate(args.cases):
        out = TASK / 'runs' / (args.label or args.mode) / case
        if out.exists():
            raise RuntimeError(f'Refusing to replace evidence: {out}')
        out.parent.mkdir(parents=True, exist_ok=True)
        m, k, n, qdir, wtrans = CASES[case]
        command = [sys.executable, str(RUNNER),
                   'improve' if args.mode == 'improve' else 'naive',
                   '--m', str(m), '--k', str(k), '--n', str(n), '--qdir', str(qdir),
                   '--wtrans', str(wtrans), '--repeat', '1', '--timeout', '7200',
                   '--build', str(build), '--output', str(out),
                   '--config', str(TASK / 'configs' / f'{args.mode}.sh')]
        if index == 0 and args.rebuild:
            command.append('--rebuild')
        if args.ucli_file:
            command += ['--ucli-file', str(args.ucli_file.resolve())]
        print(f'START {args.mode} {case}', flush=True)
        with (out.parent / f'{case}_runner.log').open('w') as log:
            rc = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
        if not (out / 'manifest.json').exists():
            raise RuntimeError(f'Runner failed before manifest: {out}')
        manifest = json.loads((out / 'manifest.json').read_text())
        wrapper = (out / 'wrapper.log').read_text(errors='replace')
        sim = (out / 'simv.log').read_text(errors='replace') if (out / 'simv.log').exists() else ''
        combined = wrapper + '\n' + sim
        result = dict(mode=args.mode, case=case, returncode=rc,
                      gemm_cycles=[int(x) for x in re.findall(r'^GEMM_LATENCY_DONE .*?\bL_gemm=(\d+)', sim, re.M)],
                      core_cycles=[int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),', wrapper, re.M)],
                      source_changes=manifest.get('source_changes_during_run'),
                      configs=manifest['configs'], strict_failure=verify.has_strict_failure(combined))
        result['passed'] = (rc == 0 and manifest.get('returncode') == 0
                            and verify.check_pass(combined) and not result['strict_failure']
                            and result['source_changes'] == []
                            and len(result['gemm_cycles']) == len(result['core_cycles']) == 1)
        if not result['passed']:
            result['errors'] = verify.extract_errors(combined)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        if not result['passed']:
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
