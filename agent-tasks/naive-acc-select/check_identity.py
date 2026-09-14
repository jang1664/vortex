#!/usr/bin/env python3
"""Compare every edited RTL translation unit to HEAD with ACC disabled."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BASE = json.loads((TASK / 'baseline.json').read_text())['commit']
OUT = TASK / 'identity'
OUT.mkdir(exist_ok=True)
changed = subprocess.check_output(
    ['git', 'diff', '--name-only', BASE, '--', 'hw/rtl'], cwd=ROOT, text=True).splitlines()
assert all(p.endswith('.sv') for p in changed), 'Header edits need a wider include-overlay comparison'
for path in changed:
    old = TASK / 'before' / path
    baseline = subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT)
    if not old.exists():
        old.parent.mkdir(parents=True, exist_ok=True)
        old.write_bytes(baseline)
    assert old.read_bytes() == baseline

dirs = sorted({p.parent for ext in ['*.vh', '*.svh'] for p in (ROOT / 'hw/rtl').rglob(ext)}
              | {ROOT / 'third_party/axi/include', ROOT / 'third_party/cvfpu/src/common_cells/include',
                 ROOT / 'third_party/cvfpu/src', ROOT / 'third_party/axi/src', ROOT / 'hw/dpi'})
flags = {mode: shlex.split(subprocess.check_output(
    ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'bash',
     str(TASK / 'configs' / f'{mode}.sh')], cwd=ROOT, text=True)) for mode in ['off', 'improve']}


def preprocess(path, mode, ndebug):
    args = ['verilator', '-E', '-DXLEN_64', '-DPERF_ENABLE', '-DGEMM_LATENCY_OBSERVER',
            '-DSIMULATION', '-DSV_DPI', '-DVCS', '-DNOXRT', '-DASSERTS_OFF',
            *(['-DNDEBUG'] if ndebug else []), *flags[mode],
            *[f'+incdir+{d}' for d in dirs], str(path)]
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True)
    text = '\n'.join(line for line in result.stdout.splitlines()
                     if not line.lstrip().startswith('`line'))
    # Generated private identifiers use source line numbers; compare their
    # bijective references, not locations shifted by inactive preprocessor arms.
    names = {}
    def rename(match):
        token = match[0]
        if token not in names:
            names[token] = f'__{match[1]}CANON{len(names)}'
        return names[token]
    text = re.sub(r'\b__(buffer_ex|pop_count_ex)[0-9]+\b', rename, text)
    return re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+|[^\s]', text)


def check(item):
    path, mode, ndebug = item
    before = preprocess(TASK / 'before' / path, mode, ndebug)
    after = preprocess(ROOT / path, mode, ndebug)
    return dict(file=path, mode=mode, ndebug=ndebug, identical=before == after,
                before_sha256=hashlib.sha256(repr(before).encode()).hexdigest(),
                after_sha256=hashlib.sha256(repr(after).encode()).hexdigest())


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(check, [(p, m, d) for p in changed for m in flags for d in [False, True]]))
result = dict(baseline=BASE, changed_rtl=changed, checks=results,
              unchanged_rtl_evidence='git diff against baseline covers all hw/rtl; no header edits')
(OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(dict(checks=len(results), different=[r for r in results if not r['identical']]), indent=2))
assert all(r['identical'] for r in results)
