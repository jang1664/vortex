#!/usr/bin/env python3
"""Sequential actual RTL regression matrix in an idle configured backend build."""
import argparse, json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument("backend",choices=("naive","improve"));p.add_argument("--build",required=True,type=Path);args=p.parse_args()
assert (args.build/"config.mk").exists()
# Refuse concurrent reuse of the required-shape capture's build.
prior=TASK/"p4-candidate"/("m256-iteration1" if args.backend=="naive" else "improve-m256-iteration1")/"manifest.json"
m=json.loads(prior.read_text());assert m["state"]=="finished" and m["passed"] and not m["source_changes_during_run"]
cases=[("lifecycle",3,64,64,0,0,3,True),
       ("qcol-wt1",16,64,64,0,1,2,False),
       ("qrow-wt0",1,64,64,1,0,2,True),
       ("qrow-wt1",3,64,64,1,1,3,True),
       ("single-n",3,64,16,0,0,2,True)]
for name,m,k,n,qdir,wt,repeat,tagged in cases:
    out=TASK/"p4-regression"/(args.backend+"-"+name+"-iteration1")
    cmd=["python3",str(TASK/"run_baseline.py"),args.backend,"--m",str(m),"--k",str(k),"--n",str(n),"--qdir",str(qdir),"--wtrans",str(wt),"--repeat",str(repeat),"--build",str(args.build),"--output",str(out),"--timeout","1800"]
    if name=="lifecycle":cmd += ["--app","fpint_gemm_lifecycle","--app-args",""]
    elif tagged:cmd += ["--tagged"]
    r=subprocess.run(cmd,cwd=ROOT)
    if r.returncode:raise SystemExit(r.returncode)
    cmd=["python3",str(TASK/"extract_latency.py"),args.backend,str(out/"wave.fsdb"),"--log",str(out/"simv.log"),"--output",str(out/"endpoints")]
    if args.backend=="naive":cmd += ["--metadata-node"]
    subprocess.run(cmd,cwd=ROOT,check=True)
    if name=="lifecycle":subprocess.run(["python3",str(TASK/"p0-lifecycle-verify.py"),str(out),"--output",str(out/"lifecycle-result.json")],cwd=ROOT,check=True)
    print("CASE COMPLETE",args.backend,name,flush=True)
