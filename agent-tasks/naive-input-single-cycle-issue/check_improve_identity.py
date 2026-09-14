"""Check that the two edited, naive-only modules have identical improve RTL."""
from pathlib import Path
import hashlib
import json
import shlex
import subprocess

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
BASE = '59be9da2'
FILES = ['hw/rtl/core/gemm/VX_naive_qparam_dma.sv',
         'hw/rtl/core/gemm/VX_naive_input_executor.sv']
snapshot = TASK / 'snapshot'
snapshot.mkdir(exist_ok=True)
profile = ROOT / 'agent-tasks/naive-psum-read-priority/baseline-improve.sh'
flags = shlex.split(subprocess.check_output(
    ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'bash', str(profile)],
    cwd=ROOT, text=True))
assert '-DGEMM_NAIVE' not in flags
dirs = sorted({p.parent for ext in ('*.vh', '*.svh') for p in (ROOT/'hw/rtl').rglob(ext)}
              | {ROOT/'third_party/axi/include', ROOT/'third_party/cvfpu/src/common_cells/include',
                 ROOT/'third_party/cvfpu/src', ROOT/'third_party/axi/src', ROOT/'hw/dpi'})
def preprocess(path, ndebug):
    args = ['verilator', '-E', '-DXLEN_64', '-DPERF_ENABLE', '-DGEMM_LATENCY_OBSERVER',
            '-DSIMULATION', '-DSV_DPI', '-DVCS', '-DNOXRT', '-DASSERTS_OFF',
            *(['-DNDEBUG'] if ndebug else []), *flags,
            *[f'+incdir+{d}' for d in dirs], str(path)]
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr[-2000:]
    return '\n'.join(x.strip() for x in p.stdout.splitlines()
                     if x.strip() and not x.lstrip().startswith('`line'))
results = []
for name in FILES:
    before = snapshot / Path(name).name
    before.write_bytes(subprocess.check_output(['git', 'show', f'{BASE}:{name}'], cwd=ROOT))
    for nd in (False, True):
        a, b = preprocess(before, nd), preprocess(ROOT/name, nd)
        results.append(dict(file=name, ndebug=nd, identical=a == b,
                            active_sha256=hashlib.sha256(b.encode()).hexdigest()))
assert all(r['identical'] for r in results)
changed = subprocess.check_output(['git', 'diff', '--name-only', BASE, '--', 'hw/rtl'], cwd=ROOT, text=True).splitlines()
assert set(changed).issubset(FILES), changed
(TASK/'improve_identity.json').write_text(json.dumps(dict(baseline=BASE, changed_rtl=changed, checks=results), indent=2)+'\n')
print(json.dumps(results))
