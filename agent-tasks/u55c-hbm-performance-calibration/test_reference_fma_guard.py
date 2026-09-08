#!/usr/bin/env python3
"""Run standalone guard tests with VCS, requiring correct pass/fatal markers."""
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
                    str(src / 'reference_fma_guard.sv'), str(src / 'tb_reference_fma_guard.sv'),
                    '-top', 'tb_reference_fma_guard', '-o', 'simv'],
                   cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
cases = {'valid': None, 'unused_c': None, 'inactive': None,
         'operand': 'OPERAND', 'madd_c': 'OPERAND', 'operation': 'OPERATION',
         'mask': 'INPUT_CONTROL', 'result': 'RESULT', 'valid_x': 'VALID',
         'ready_x': 'INPUT_CONTROL', 'out_mask': 'OUTPUT_CONTROL'}
for case, expected in cases.items():
    run = subprocess.run([str(out / 'simv'), f'+case={case}'], cwd=out,
                         capture_output=True, text=True, timeout=30)
    text = run.stdout + run.stderr
    (out / f'{case}.log').write_text(text)
    if expected:
        assert 'Fatal:' in text and f'REFERENCE_FMA_GUARD_{expected}' in text, text
        assert 'REFERENCE_FMA_GUARD_PASS' not in text, text
    else:
        assert run.returncode == 0 and 'Fatal:' not in text and 'REFERENCE_FMA_GUARD_PASS' in text, text
print(f'FMA boundary guard: {len(cases)} cases passed')
