#!/usr/bin/env python3
"""Directed VCS boundary tests; fatal markers matter even with exit zero."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, required=True)
args = parser.parse_args()
out = args.output_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
src = Path(__file__).resolve().parent
vcs = shutil.which('vcs')
if not vcs:
    raise RuntimeError('VCS unavailable')
with (out / 'compile.log').open('w') as log:
    subprocess.run([vcs, '-full64', '-sverilog', '-timescale=1ns/1ps', '-xprop=tmerge',
                    str(src / 'reference_binary_fp_guard.sv'),
                    str(src / 'tb_reference_binary_fp_guard.sv'),
                    '-top', 'tb_reference_binary_fp_guard', '-o', 'simv'],
                   cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
cases = dict.fromkeys(('valid', 'idle', 'stalled', 'a_only', 'b_only'))
cases.update(av='VALID', bv='VALID', rv='VALID', ar='A_READY', br='B_READY',
             rr='RESULT_READY', a='A_DATA', b='B_DATA', result='RESULT_DATA',
             stalled_a='A_DATA', stalled_result='RESULT_DATA')
for case, expected in cases.items():
    run = subprocess.run([str(out / 'simv'), f'+case={case}'], cwd=out,
                         capture_output=True, text=True, timeout=30)
    text = run.stdout + run.stderr
    (out / f'{case}.log').write_text(text)
    if expected:
        assert 'Fatal:' in text and f'REFERENCE_BINARY_FP_{expected}' in text, text
        assert 'REFERENCE_BINARY_FP_PASS' not in text, text
    else:
        assert run.returncode == 0 and 'Fatal:' not in text and 'REFERENCE_BINARY_FP_PASS' in text, text
print(f'Binary FP boundary guard: {len(cases)} cases passed')
