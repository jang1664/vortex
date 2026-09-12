#!/usr/bin/env python3
"""Capture naive depth16 DMA baseline, retaining weight8 and PSUM16."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
TASK = Path(__file__).resolve().parent
RUNNER = ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--depth', type=int, required=True)
parser.add_argument('--m', type=int, choices=[4,256])
args = parser.parse_args()
BUILD = ROOT / 'build_dma_slots_naive16_vcs'
spec = importlib.util.spec_from_file_location('verify_rtl', ROOT / 'tools/verify_rtl.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def main():
    results = []
    for m in ([args.m] if args.m else (4, 256)):
        out = TASK.parent / 'runs' / 'naive' / f'slots{args.depth}-m{m}'
        config = TASK / f'slots{args.depth}.sh'
        if not config.exists():
            config.write_text('source "' + str(ROOT / 'agent-tasks/dma-read-slot-saturation/baseline-naive.sh') + '"\nCONFIGS+=" -DDMA_NODE_RD_OUTSTANDING_SLOT=' + str(args.depth) + '"\nexport CONFIGS\n')
        cmd = [sys.executable, str(RUNNER), 'naive', '--m', str(m),
               '--k', '512', '--n', '512', '--qdir', '0', '--wtrans', '0',
               '--repeat', '1', '--timeout', '7200', '--build', str(BUILD),
               '--output', str(out), '--config', str(config)]
        if m == 4:
            cmd.append('--rebuild')
        print(f'Starting M{m}', flush=True)
        run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        out.mkdir(parents=True, exist_ok=True)
        (out / 'runner.log').write_text(run.stdout + run.stderr)
        manifest = json.loads((out / 'manifest.json').read_text())
        wrapper = (out / 'wrapper.log').read_text(errors='replace')
        simv = (out / 'simv.log').read_text(errors='replace') if (out / 'simv.log').exists() else ''
        combined = wrapper + '\n' + simv
        done_lines = [s for s in simv.splitlines() if s.startswith('GEMM_LATENCY_DONE ')]
        gemm = [int(re.search(r'\bL_gemm=(\d+)', s)[1]) for s in done_lines]
        core = [int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),', wrapper, re.M)]
        result = dict(dma_read_slots=args.depth, weight_slots=8, psum_read_slots=16, psum_response_slots=16, m=m, k=512, n=512, runner_returncode=run.returncode,
                      wrapper_returncode=manifest.get('returncode'),
                      tool_pass=verify.check_pass(combined),
                      strict_failure=verify.has_strict_failure(combined),
                      source_changes=manifest.get('source_changes_during_run'),
                      gemm_cycles=gemm, core_cycles=core,
                      observer_done=done_lines, perf=manifest.get('perf', []),
                      log_dir=str(out.relative_to(ROOT)))
        result['passed'] = (run.returncode == 0 and result['wrapper_returncode'] == 0
                            and result['tool_pass'] and not result['strict_failure']
                            and result['source_changes'] == [] and len(gemm) == 1
                            and len(core) == 1 and bool(simv))
        if not result['passed']:
            result['error_excerpt'] = verify.extract_errors(combined)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        results.append(result)
        (TASK / f'results-slots{args.depth}.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        if not result['passed']:
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
