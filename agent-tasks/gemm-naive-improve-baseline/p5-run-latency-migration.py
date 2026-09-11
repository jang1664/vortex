#!/usr/bin/env python3
import json,os,shutil,subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
OUT=TASK/'p5-verification/latency-migration-iteration2';OUT.mkdir(parents=True,exist_ok=False)
def run(backend):
 build=ROOT/('build_fpint_latency_'+backend+'_vcs');assert (build/'config.mk').exists()
 directory=build/'hw/unittest/gemm_latency_observer';directory.mkdir(parents=True,exist_ok=True)
 shutil.copy2(ROOT/'hw/unittest/gemm_latency_observer/Makefile',directory/'Makefile')
 config=subprocess.check_output(['bash','-c',f'source agent-tasks/fpint-gemm-latency-compare/{backend}.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
 cmd=['python3',str(ROOT/'tools/verify_rtl.py'),'unittest','--path',str(directory),'--sim','vcs',f'--params=-B TEST=controller BACKEND={backend}']
 if backend=='naive':cmd += ['--extra-sim-args','+M=3 +K=64 +N=64 +DELIVERY_DELAY=17 +STORE_DELAY=19']
 result=subprocess.run(cmd,cwd=build,env=dict(os.environ,CONFIGS=config,BACKEND=backend,TEST='controller',MAKEFLAGS='-B',CC='/usr/bin/gcc',CXX='/usr/bin/g++'),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 case=OUT/backend;case.mkdir();(case/'result.json').write_text(result.stdout);(case/'command.json').write_text(json.dumps({'cmd':cmd,'configs':config},indent=2)+'\n')
 for name in ('compile.log','sim.log'):
  src=directory/'logs'/name
  if src.exists():shutil.copy2(src,case/name)
 print(backend,result.returncode,result.stdout[-1200:],flush=True)
 return {'backend':backend,'returncode':result.returncode}
with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,('naive',)))
(OUT/'summary.json').write_text(json.dumps(results,indent=2)+'\n');raise SystemExit(0 if all(r['returncode']==0 for r in results) else 1)
