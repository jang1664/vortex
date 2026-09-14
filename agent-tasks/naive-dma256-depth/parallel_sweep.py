#!/usr/bin/env python3
"""Bounded parallel runs; each variant owns its configured build and sockets."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess,sys
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
variants=sys.argv[1:] or ['d16_r32_ordered','d32_r32_ordered','d64_r32_ordered','d128_r32_ordered','d128_r64_ordered','d128_r128_ordered']
def run(v):
 with (TASK/f'{v}.log').open('w') as log:rc=subprocess.run([sys.executable,str(TASK/'run.py'),v],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
 print(v,rc,flush=True);return rc
with ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(run,variants))
sys.exit(int(any(results)))
