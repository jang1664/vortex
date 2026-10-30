#!/usr/bin/env python3
"""Preprocess paired C4 feature-off sources without elaborating or simulating."""
import hashlib, io, json, os, re, shlex, subprocess, tarfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'agent-tasks/c4-unified-mmio/feature_off_identity'
OUT.mkdir(exist_ok=True)
BASE = OUT / 'baseline'
BASE.mkdir(exist_ok=True)
archive = subprocess.check_output(['git','archive','12382c883','hw/rtl'],cwd=ROOT)
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    tar.extractall(BASE, filter='data')
config = 'configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh'
flags = shlex.split(subprocess.check_output(['bash','-c',f'source {config}; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True))
assert '-DGEMM_SRAM_FUSION' not in flags
flags += ['-DXLEN_64','-DNDEBUG','-DSYNTHESIS']
files = ['hw/rtl/core/VX_core.sv','hw/rtl/core/VX_job_frontend.sv',
         'hw/rtl/core/VX_job_desc_mmio_regs.sv','hw/rtl/core/gemm/VX_gemm_node.sv']
incs = ['hw/rtl','hw/rtl/libs','hw/rtl/core','hw/rtl/core/gemm','hw/rtl/mem','hw/rtl/interfaces','hw/rtl/fpu','hw/rtl/tcu']
result = {'baseline':'12382c883','config':config,'defines':flags,'files':[]}
for source in files + ['hw/rtl/VX_config.vh']:
    outputs = {}
    for name, root in [('baseline',BASE),('candidate',ROOT)]:
        args = ['verilator','-E','-P','-Wno-fatal'] + flags + ['-I'+v for v in incs]
        if source.endswith('.vh'): args += ['--dump-defines']
        proc = subprocess.run(args+[source],cwd=root,text=True,capture_output=True)
        (OUT / (name+'_'+Path(source).name+'.stderr')).write_text(proc.stderr)
        if proc.returncode: raise RuntimeError(proc.stderr)
        content = proc.stdout
        if source.endswith('.vh'):
            content = '\n'.join(sorted(content.splitlines()))+'\n'
        outputs[name] = content
        (OUT / (name+'_'+Path(source).name+'.pp')).write_text(content)
    # -P removes source locations and comments. Ignore only formatting spaces.
    normalized = {k:re.sub(r'\s+','',v) for k,v in outputs.items()}
    record = {'source':source,'identical':normalized['baseline']==normalized['candidate'],
              'byte_identical':outputs['baseline']==outputs['candidate'],
              'sha256':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in normalized.items()}}
    result['files'].append(record)
result['all_identical'] = all(r['identical'] for r in result['files'])
(OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
raise SystemExit(0 if result['all_identical'] else 1)
