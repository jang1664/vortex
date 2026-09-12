#!/usr/bin/env python3
import hashlib,json,os,shlex,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]; TASK=Path(__file__).resolve().parent
BUILD=ROOT/'build_fpint_latency_naive_vcs'; OUT=TASK/'p5-verification/controller-endpoints-iteration1'
OUT.mkdir(parents=True,exist_ok=False)
assert 'XLEN' in (BUILD/'config.mk').read_text()
directory=BUILD/'hw/unittest/naive_meta_control';directory.mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'hw/unittest/naive_meta_control/Makefile',directory/'Makefile')
config=subprocess.check_output(['bash','-c','source agent-tasks/fpint-gemm-latency-compare/naive.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ('hw/rtl','hw/unittest/naive_meta_control') for p in (ROOT/base).rglob('*') if p.is_file()}
results=[]
for mxu in (16,32):
 defines=[d for d in shlex.split(config) if not any(d.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
 defines += ['-D'+k+'='+str(mxu) for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS')]
 env=dict(os.environ,CONFIGS=' '.join(defines),CC='/usr/bin/gcc',CXX='/usr/bin/g++')
 for store in (0,19):
  for delay in (0,1,17):
   case=OUT/f'mx{mxu}-store{store}-delivery{delay}';case.mkdir()
   cmd=['python3',str(ROOT/'tools/verify_rtl.py'),'unittest','--path',str(directory),'--sim','vcs','--params=-B','--extra-sim-args',f'+M=3 +K=64 +N=64 +DELIVERY_DELAY={delay} +STORE_DELAY={store}']
   result=subprocess.run(cmd,cwd=BUILD,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   (case/'result.json').write_text(result.stdout);(case/'command.json').write_text(json.dumps(dict(command=cmd,configs=env['CONFIGS']),indent=2)+'\n')
   for log in ('compile.log','sim.log'):
    src=directory/'logs'/log
    if src.exists():shutil.copy2(src,case/log)
   records=dict(mxu=mxu,store_delay=store,delivery_delay=delay,returncode=result.returncode)
   results.append(records);print(json.dumps(records),flush=True)
   (OUT/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
   if result.returncode: print(result.stdout[-1600:],flush=True);raise SystemExit(result.returncode)
assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in sources.items())
(OUT/'source-hashes.json').write_text(json.dumps(sources,indent=2)+'\n')
