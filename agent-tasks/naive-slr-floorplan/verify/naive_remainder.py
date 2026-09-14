#!/usr/bin/env python3
"""Run a serialized mode lane after its immutable baseline simulation completes."""
import json, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
mode=sys.argv[1]
wait=ROOT/('agent-tasks/naive-slr-floorplan/runs/baseline-naive-off-short4/manifest.json' if mode=='off' else 'agent-tasks/naive-slr-floorplan/runs/baseline-improve-on-m256/manifest.json')
while not wait.exists() or json.loads(wait.read_text()).get('state') != 'finished': time.sleep(10)
source=ROOT/'build_naive_slr_candidate_source'
runs=[]
# Start with naive smoke tests, then improve preservation, then naive active matrix.
for backend, m,k,n,tag,w,d,repeat in ([('naive',16,64,64,True,w,d,2) for w in [0,1] for d in [0,1]] if mode=='on' else []) + [('naive',4,512,512,False,0,0,1),('naive',256,512,512,False,0,0,1)]:
 label=f'candidate-{backend}-{mode}-m{m}-n{n}-k{k}'+(f'-tag-w{w}-d{d}' if tag else '')
 out=ROOT/'agent-tasks/naive-slr-floorplan/runs'/label
 cmd=[sys.executable,str(ROOT/'agent-tasks/naive-slr-floorplan/verify/run.py'),str(source),backend,'--m',str(m),'--k',str(k),'--n',str(n),'--build',str(source/f'build_{backend}_{mode}'),'--config',str(source/f'configs/verify_{backend}_{mode}.sh'),'--output',str(out),'--wtrans',str(w),'--qdir',str(d),'--repeat',str(repeat),'--timeout','7200']
 if tag: cmd+=['--tagged']
 print('START '+label,flush=True)
 rc=subprocess.call(cmd,cwd=ROOT)
 runs.append(dict(label=label,returncode=rc))
 (ROOT/f'agent-tasks/naive-slr-floorplan/verify/naive_remainder_{mode}.json').write_text(json.dumps(runs,indent=2)+'\n')
 if rc: sys.exit(rc)
