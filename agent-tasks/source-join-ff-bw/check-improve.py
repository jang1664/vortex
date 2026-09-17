#!/usr/bin/env python3
"""Check that this change is absent from improve RTL after preprocessing."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / 'verification' / 'improve-identity'
OUT.mkdir(parents=True, exist_ok=False)
changed = subprocess.check_output(
    ['git', 'diff', 'HEAD', '--name-only', '--', 'hw/rtl'], cwd=ROOT,
    text=True).splitlines()
assert set(changed) == {
    'hw/rtl/core/gemm/VX_naive_source_join.sv',
    'hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv',
}, changed
config = subprocess.check_output(
    ['bash', '-c', 'source configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh; '
     'printf "%s" "$CONFIGS"'], cwd=ROOT, text=True)
assert '-DGEMM_NAIVE' not in config
includes = sorted({p.parent for p in (ROOT / 'hw/rtl').rglob('*.vh')})
records = []
for name in changed:
    before = subprocess.check_output(['git', 'show', f'HEAD:{name}'], cwd=ROOT)
    after = (ROOT / name).read_bytes()
    for perf in (False, True):
        processed = {}
        commands = {}
        for revision, data in [('before', before), ('after', after)]:
            path = OUT / revision / Path(name).name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data)
            cmd = ['verilator', '-E', '-DXLEN_64', *shlex.split(config)]
            if perf:
                cmd.append('-DPERF_ENABLE')
            cmd += [f'+incdir+{p}' for p in includes] + [str(path)]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            processed[revision] = '\n'.join(
                line.rstrip() for line in result.stdout.splitlines()
                if line.strip() and not line.lstrip().startswith('`line'))
            commands[revision] = cmd
        assert processed['before'] == processed['after'], name
        assert not processed['after'].strip(), name
        records.append(dict(file=name, perf=perf, equal=True, empty=True,
                            commands=commands,
                            before_sha256=hashlib.sha256(before).hexdigest(),
                            after_sha256=hashlib.sha256(after).hexdigest()))
result = dict(status='pass', changed_rtl=changed, comparisons=records,
              scope='Only two naive-guarded modules changed; both preprocess '
                    'to empty under improve TH16/MXU16 with PERF off and on. '
                    'All other tracked RTL is unchanged from HEAD. No synthesis.')
(OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(result['scope'])
print('PASS:', len(records), 'comparisons')
