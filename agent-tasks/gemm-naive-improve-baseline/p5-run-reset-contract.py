#!/usr/bin/env python3
import hashlib,json,os,shlex,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
OUT=TASK/'p5-verification/reset-contract-iteration1';OUT.mkdir(parents=True,exist_ok=False)
BUILD=ROOT/'build_naive_input_contexts_verify';assert (BUILD/'config.mk').exists()
directory=BUILD/'hw/unittest/naive_node_integration'
for name in ('Makefile','vcs.mk'):shutil.copy2(ROOT/'hw/unittest/naive_node_integration'/name,directory/name)
config=subprocess.check_output(['bash','-c','source agent-tasks/fpint-gemm-latency-compare/naive.sh; printf "%s" "$CONFIGS"'],cwd=ROOT,text=True)
source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'hw/rtl').rglob('*') if p.is_file()}
results=[]
for mx in (16,32):
 defines=[d for d in shlex.split(config) if not any(d.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
 defines += ['-D'+k+'='+str(mx) for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS')]
 env=dict(os.environ,CONFIGS=' '.join(defines),MAKEFLAGS='-B',CC='/usr/bin/gcc',CXX='/usr/bin/g++')
 cmd=['python3',str(ROOT/'tools/verify_rtl.py'),'unittest','--path',str(directory),'--sim','vcs','--timeout','600']
 case=OUT/f'mx{mx}';case.mkdir()
 result=subprocess.run(cmd,cwd=BUILD,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (case/'result.json').write_text(result.stdout);(case/'command.json').write_text(json.dumps({'cmd':cmd,'configs':env['CONFIGS'],'makeflags':env['MAKEFLAGS']},indent=2)+'\n')
 for name in ('compile.log','sim.log'):
  src=directory/'logs'/name
  if src.exists():shutil.copy2(src,case/name)
 results.append(dict(mxu=mx,case='initial_and_quiescent_reset',returncode=result.returncode));(OUT/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
 print(mx,result.returncode,result.stdout[-1300:],flush=True)
 if result.returncode:raise SystemExit(result.returncode)
 negative=OUT/f'mx{mx}-active-negative';negative.mkdir()
 negative_cmd=cmd+['--extra-sim-args=+ACTIVE_RESET_NEGATIVE']
 negative_result=subprocess.run(negative_cmd,cwd=BUILD,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (negative/'result.json').write_text(negative_result.stdout)
 (negative/'command.json').write_text(json.dumps({'cmd':negative_cmd,'configs':env['CONFIGS'],'expected':'naive active-invocation reset is unsupported'},indent=2)+'\n')
 for name in ('compile.log','sim.log'):
  src=directory/'logs'/name
  if src.exists():shutil.copy2(src,negative/name)
 parsed=json.loads(negative_result.stdout)
 correct=negative_result.returncode!=0 and parsed['status']=='sim_fail' and 'naive active-invocation reset is unsupported' in parsed['error_log'] and 'ACTIVE_RESET_JOB_ACCEPTED' in (negative/'sim.log').read_text()
 results.append(dict(mxu=mx,case='active_reset_expected_failure',matched_expected_diagnostic=correct,returncode=negative_result.returncode))
 (OUT/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
 print('active-reset',mx,correct,negative_result.stdout[-1000:],flush=True)
 if not correct:raise SystemExit(1)
assert all(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h for n,h in source_hashes.items())
(OUT/'source-hashes.json').write_text(json.dumps(source_hashes,indent=2)+'\n')
