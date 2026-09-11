#!/usr/bin/env python3
"""Compare unchanged default16 naive and improve preprocessing against HEAD."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
OUT = TASK / 'runs' / 'default-identity'
OUT.mkdir(parents=True, exist_ok=False)
helper = ROOT / 'agent-tasks/gemm-naive-improve-baseline/p1-improve-preprocess.py'
spec = importlib.util.spec_from_file_location('normalize', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
name = 'hw/rtl/core/gemm/VX_gemm_node_naive.sv'
changed = subprocess.check_output(
    ['git', 'diff', 'HEAD', '--name-only', '--', 'hw/rtl'], cwd=ROOT,
    text=True).splitlines()
assert changed == [name], changed
versions = dict(before=subprocess.check_output(['git', 'show', f'HEAD:{name}'], cwd=ROOT),
                after=(ROOT / name).read_bytes())
includes = sorted({p.parent for p in (ROOT / 'hw/rtl').rglob('*.vh')})
records = []
for backend in ('naive', 'improve'):
    config_path = f'agent-tasks/fpint-gemm-latency-compare/{backend}.sh'
    config = subprocess.check_output(
        ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'bash', config_path],
        cwd=ROOT, text=True)
    for perf in (False, True):
        output = {}
        commands = {}
        for revision, data in versions.items():
            path = OUT / revision / Path(name).name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data)
            cmd = ['verilator', '-E', '-DXLEN_64', *shlex.split(config)]
            if perf:
                cmd.append('-DPERF_ENABLE')
            cmd += [f'+incdir+{p}' for p in includes] + [str(path)]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            output[revision] = module.normalized(result.stdout).strip()
            commands[revision] = cmd
        assert output['before'] == output['after'], (backend, perf)
        if backend == 'improve':
            assert not output['after']
        records.append(dict(backend=backend, perf=perf, equal=True,
                            commands=commands,
                            normalized_sha256=hashlib.sha256(output['after'].encode()).hexdigest()))
report = dict(status='pass', reference_commit=subprocess.check_output(
    ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    changed_rtl=changed, comparisons=records,
    scope='Naive default16 and improve preprocessing identical to HEAD; '
          'all other tracked RTL unchanged. Normalize only blank/source-location '
          'lines and known line-generated helper names; no synthesis.')
(OUT / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS: naive default16 and improve, PERF off/on, four RTL comparisons')
