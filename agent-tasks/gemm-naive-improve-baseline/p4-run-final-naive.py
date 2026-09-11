#!/usr/bin/env python3
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
cases=[("naive-qrow-wt1-iteration1",3,64,64,1,1,3,True),
       ("naive-single-n-iteration1",3,64,16,0,0,2,True),
       ("naive-tail-m17k160n48-iteration1",17,160,48,1,1,1,True),
       ("naive-m4-final1",4,512,512,0,0,1,False),
       ("naive-m256-final1",256,512,512,0,0,1,False)]
for name,m,k,n,qdir,wt,repeat,tagged in cases:
 out=TASK/"p4-regression"/name
 cmd=["python3",str(TASK/"run_baseline.py"),"naive","--m",str(m),"--k",str(k),"--n",str(n),"--qdir",str(qdir),"--wtrans",str(wt),"--repeat",str(repeat),"--build","build_naive_input_contexts_verify","--output",str(out),"--timeout","5400"]
 if tagged:cmd += ["--tagged"]
 subprocess.run(cmd,cwd=ROOT,check=True)
 subprocess.run(["python3",str(TASK/"extract_latency.py"),"naive",str(out/"wave.fsdb"),"--metadata-node","--log",str(out/"simv.log"),"--output",str(out/"endpoints")],cwd=ROOT,check=True)
 print("CASE COMPLETE",name,flush=True)
