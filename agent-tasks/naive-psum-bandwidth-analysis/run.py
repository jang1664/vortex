"""Capture current naive slot32 waveforms, preserving source and run manifests."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
for m in (4, 256):
    command = [sys.executable, str(ROOT / 'agent-tasks/gemm-naive-improve-baseline/run_baseline.py'),
               'naive', '--m', str(m), '--timeout', '7200',
               '--build', str(ROOT / 'build_naive_psum32_vcs'),
               '--config', str(ROOT / 'agent-tasks/naive-psum-slot-sweep/slots32.sh'),
               '--output', str(TASK / 'runs' / f'naive-m{m}')]
    if m == 4:
        command.append('--rebuild')
    print(f'Starting M{m}', flush=True)
    subprocess.run(command, cwd=ROOT, check=True)
