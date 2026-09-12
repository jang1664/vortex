#!/usr/bin/env python3
"""Measure current RTL with matched th16/MXU16 geometry."""
import json, os, re, shutil, subprocess, sys
from datetime import datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
name=sys.argv[1]
build=ROOT/f'build_fpint_latency_{name}_vcs'
out=ROOT/'docs/hw_analysis/improve_vs_naive/logs'/f'vcs_{name}'
out.mkdir(exist_ok=True)
raw=subprocess.check_output(['bash','-c','source "$1"; env -0','bash',str(Path(__file__).parent/f'{name}.sh')],cwd=ROOT)
env=dict(v.split('=',1) for v in raw.decode().split('\0') if '=' in v)
for k in ['DEBUG','PERF','SCOPE','LOG_MAX_BYTES','VCS_SIMV_FLAGS','FPGA_BIN_DIR','XRT_XCLBIN_PATH']:
    env.pop(k,None)
env['CONFIGS'] += ' -DDISABLE_FSDB'
env.update(CC='/usr/bin/gcc',CXX='/usr/bin/g++',GUI='0',PATH='/usr/bin:'+env['PATH'])
app='fpint_gemm_ffn_hw'+('_naive' if name.startswith('naive') else '')
manifest={'name':name,'started':datetime.now().isoformat(),'CONFIGS':env['CONFIGS'],'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'memory_environment':{k:v for k,v in env.items() if k.startswith(('DRAM_','CACHE_'))},'runs':[]}
for m in ([4] if name == "naive32" else [4,256]):
    log=out/f'm{m}.log'
    cmd=['timeout','1800','ci/run_black.sh','xrt-vcs-sim','--perf','3','--app',app,'--args',f'-m {m} -k 512 -n 512 -q 32 -t 0 -d 0 -r 1']
    print('START',name,m,flush=True)
    with log.open('w') as f:
        rc=subprocess.run(cmd,cwd=build,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
    for src,dest in [('simv.log',f'm{m}_simv.log'),('u55c_model_manifest.json','u55c_model_manifest.json')]:
        path=build/'sim/xrtsim_vcs'/src
        if path.exists(): shutil.copy2(path,out/dest)
    text=log.read_text(errors='replace')
    perf=[l for l in text.splitlines() if l.startswith('PERF:')]
    row={'M':m,'command':cmd,'returncode':rc,'passed':bool(re.search(r'^PASSED$',text,re.M)),'perf':perf}
    manifest['runs'].append(row)
    (out/'results.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('RESULT',name,m,rc,row['passed'],perf,flush=True)
    if rc or not row['passed']: sys.exit(1)
