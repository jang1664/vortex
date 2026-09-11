#!/usr/bin/env python3
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
for m in (4,256):
 cmd=['python3',str(TASK/'p5-run-final-blackbox.py'),'naive','--m',str(m),'--k','512','--n','512','--build',str(ROOT/'build_naive_input_contexts_verify'),'--output',str(TASK/f'p5-final-pass/naive-m{m}'),'--timeout','5400']
 if m==4:cmd.append('--rebuild')
 print('START M',m,flush=True)
 result=subprocess.run(cmd,cwd=ROOT)
 if result.returncode:raise SystemExit(result.returncode)
 print('COMPLETE M',m,flush=True)
