#!/usr/bin/env python3
"""Compare selected improve RTL with a complete pre-merge include tree."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
from verify import ROOT, BASE, EXEC, environment

OUT = EXEC / 'identity'
OUT.mkdir(exist_ok=True)
SCOPE = {Path(x) for x in ['.', 'libs', 'interfaces', 'core', 'core/gemm',
                         'mem', 'cache', 'fpu', 'verification', 'afu/xrt']}
trees = [BASE / 'hw/rtl', ROOT / 'hw/rtl']
files = sorted({p.relative_to(tree) for tree in trees for p in tree.rglob('*')
                if p.suffix in ('.sv', '.v') and p.parent.relative_to(tree) in SCOPE
                and p.name != 'VX_mem_bus_split.sv'})
includes = {tree: sorted({p.parent for ext in ['*.vh', '*.svh'] for p in tree.rglob(ext)}
             | {ROOT / 'third_party/axi/include', ROOT / 'third_party/cvfpu/src/common_cells/include',
                ROOT / 'third_party/cvfpu/src', ROOT / 'third_party/axi/src', ROOT / 'hw/dpi'})
            for tree in trees}
flags = {profile: shlex.split(environment(BASE, profile)['CONFIGS'])
         for profile in ['improve_off', 'improve_on']}


def preprocess(tree, rel, profile, ndebug):
    path = tree / rel
    if not path.exists():
        return []
    cmd = ['verilator', '-E', '-DXLEN_64', '-DPERF_ENABLE', '-DGEMM_LATENCY_OBSERVER',
           '-DSIMULATION', '-DSV_DPI', '-DVCS', '-DNOXRT', '-DASSERTS_OFF',
           *(['-DNDEBUG'] if ndebug else []), *flags[profile],
           *[f'+incdir+{d}' for d in includes[tree]], str(path)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=True)
    text = '\n'.join(s for s in result.stdout.splitlines() if not s.lstrip().startswith('`line'))
    names = {}
    def rename(match):
        token = match[0]
        if token not in names:
            names[token] = f'__{match[1]}CANON{len(names)}'
        return names[token]
    text = re.sub(r'\b__(buffer_ex|pop_count_ex)[0-9]+\b', rename, text)
    return re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+|[^\s]', text)


def check(item):
    rel, profile, ndebug = item
    before, after = [preprocess(tree, rel, profile, ndebug) for tree in trees]
    same = before == after
    if not same:
        prefix = OUT / (str(rel).replace('/', '__') + f'.{profile}.{ndebug}')
        prefix.with_suffix(prefix.suffix + '.before').write_text(' '.join(before))
        prefix.with_suffix(prefix.suffix + '.after').write_text(' '.join(after))
    digest = lambda tokens: hashlib.sha256(json.dumps(tokens).encode()).hexdigest()
    return dict(file=str(rel), profile=profile, ndebug=ndebug, identical=same,
                before_sha256=digest(before), after_sha256=digest(after))


if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(check, [(p, profile, ndebug) for p in files
                              for profile in flags for ndebug in [False, True]]))
    record = dict(baseline='b04c54c00f9f1b7b3b483b50335e43c3c7a3dab4',
                  files=len(files), checks=len(results), passed=all(r['identical'] for r in results),
                  excluded='mem/VX_mem_bus_split.sv: separately verify absence from improve elaboration',
                  normalization='Whitespace, line directives, bijective line-derived private identifiers only',
                  results=results)
    (OUT / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({k: v for k, v in record.items() if k != 'results'}), flush=True)
    raise SystemExit(0 if record['passed'] else 1)
