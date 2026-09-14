#!/usr/bin/env python3
"""Check final guard/format cleanup against the measured reorder implementation."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

T = Path(__file__).resolve().parent
ROOT = T.parents[1]
before = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'hw/rtl/mem/VX_mem_bus_split.sv'
after = Path(sys.argv[2]) if len(sys.argv) > 2 else T / 'final_candidate/VX_mem_bus_split.sv'

def preprocess(path, flags, ndebug):
    command = ['verilator', '-E', '-DXLEN_64', '-DSIMULATION', '-DVCS',
               *(['-DNDEBUG'] if ndebug else []), f'-I{ROOT}/hw/rtl', *flags, str(path)]
    p = subprocess.run(command, capture_output=True, text=True, check=True)
    return '\n'.join(x for x in p.stdout.splitlines() if not x.lstrip().startswith('`line'))

def tokens(text):
    # The only non-guard API addition is an unused label for optional tracing.
    # Its debug block is absent from the measured, trace-disabled configuration.
    text = re.sub(r'parameter\s+(?:string\s+)?INSTANCE_ID\s*=\s*""\s*,', '', text)
    return re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+\x27[sS]?[bBoOdDhH][0-9a-fA-F_xzXZ?]+|\d+|[^\s]', text)

checks = []
for config in ['d8_r32_ordered', 'd128_r128_ordered']:
    flags = shlex.split(subprocess.check_output(
        ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'bash', str(T / 'configs' / (config + '.sh'))],
        cwd=ROOT, text=True))
    for ndebug in [False, True]:
        a = tokens(preprocess(before, flags, ndebug))
        b = tokens(preprocess(after, flags, ndebug))
        checks.append(dict(config=config, ndebug=ndebug, identical=a == b,
                           token_count=len(a), before=hashlib.sha256(repr(a).encode()).hexdigest(),
                           after=hashlib.sha256(repr(b).encode()).hexdigest()))
improve = preprocess(after, ['-DGEMM_IMPROVE'], True)
result = dict(before=str(before), after=str(after), checks=checks,
              excluded='Unused INSTANCE_ID string parameter for optional debug tracing only',
              improve_reorder_module_absent='VX_mem_bus_split_reorder' not in improve)
(T / 'identity/guarded_candidate.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
assert all(x['identical'] for x in checks)
assert result['improve_reorder_module_absent']
