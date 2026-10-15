#!/usr/bin/env python3
"""Classify run_black.sh logs using the repository verification predicates."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--log', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--name', required=True)
parser.add_argument('--returncode', type=int, required=True)
parser.add_argument('--iteration', type=int, default=1)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('verify_rtl', repo / 'tools/verify_rtl.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
text = args.log.read_text(errors='replace')
if args.returncode == 0 and verify.check_pass(text):
    status = 'pass'
elif re.search(r'^Error-|Syntax error|fatal error:', text, re.MULTILINE):
    status = 'compile_error'
else:
    status = 'sim_fail'
report = {
    'status': status, 'test_name': args.name, 'iteration': args.iteration,
    'returncode': args.returncode, 'log_file': str(args.log.resolve()),
    'error_log': '' if status == 'pass' else verify.extract_errors(text),
    'core_cycles': [int(x) for x in re.findall(r'PERF: instrs=\d+, cycles=(\d+)', text)],
    'gemm_total_cycles': [int(x) for x in re.findall(r'PERF: jobs=\d+ total_cycles=(\d+)', text)],
    'perf': [line for line in text.splitlines() if line.startswith('PERF:')],
    'verification': [line for line in text.splitlines() if line.startswith(('Verification:', 'Verified job', 'Job '))],
}
if args.returncode == 124:
    report['failure_reason'] = 'wall-clock timeout; no functional failure inferred'
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: report[key] for key in ('status', 'test_name', 'core_cycles', 'gemm_total_cycles')}))
raise SystemExit(0 if status == 'pass' else 1)
