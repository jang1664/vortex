import argparse, json, subprocess, shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/"agent-tasks/source-join-ff-bw/verification/unittests"
OUT.mkdir(parents=True,exist_ok=True)
parser=argparse.ArgumentParser(description="Run VCS source-join/FSM/control regression in the configured build")
parser.add_argument("--reuse-existing",action="store_true",help="Resume unchanged RTL/test run using retained case logs")
options=parser.parse_args()
rows=[]
def run_case(mxu,env,suite,name,args,diagnostic=None):
    dest=OUT/f"mxu{mxu}"/suite/name
    dest.mkdir(parents=True,exist_ok=True)
    work=ROOT/"build/hw/unittest"/suite
    cmd=["python3",str(ROOT/"tools/verify_rtl.py"),"unittest","--path",str(work),"--sim","vcs","--extra-sim-args",args]
    cached=options.reuse_existing and (dest/"verify.json").exists() and (dest/"sim.log").exists()
    if cached:
        proc=subprocess.CompletedProcess(cmd,0,(dest/"verify.json").read_text())
    else:
        proc=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (dest/"verify.json").write_text(proc.stdout)
        for logfile in ("sim.log","compile.log"):
            if (work/"logs"/logfile).exists():shutil.copy2(work/"logs"/logfile,dest/logfile)
    result=json.loads(proc.stdout)
    raw=(dest/"sim.log").read_text() if (dest/"sim.log").exists() else ""
    good=(result["status"]=="sim_fail" and diagnostic in raw and "Fatal:" in raw and "Missing expected" not in raw) if diagnostic else result["status"]=="pass" and proc.returncode==0
    rows.append(dict(mxu=mxu,suite=suite,name=name,args=args,expected=diagnostic or "pass",status="pass" if good else "fail"))
    (OUT/"results.json").write_text(json.dumps(rows,indent=2)+"\n")
    print(f"MXU{mxu} {suite}/{name}: {rows[-1]['status']}",flush=True)
    if not good:raise RuntimeError(proc.stdout)
    return dest
for mxu,config in [(16,"naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh"),(32,"naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16.sh")]:
    config_path=ROOT/"configs"/config
    raw=subprocess.check_output(["bash","-c",'source "$1"; env -0',"source-config",str(config_path)])
    env=dict(x.decode().split("=",1) for x in raw.split(b"\0") if x)
    env.update(CC="/usr/bin/gcc",CXX="/usr/bin/g++")
    (OUT/f"mxu{mxu}").mkdir(exist_ok=True)
    (OUT/f"mxu{mxu}"/"config.txt").write_text(str(config_path)+"\n"+env["CONFIGS"]+"\n")
    run_case(mxu,env,"naive_source_join","positive","+CASE=positive")
    for case in ("duplicate","foreign_generation","duplicate_closure","zero_work","zero_count","large_count","high_count","zero_generation","simultaneous_generation","outside_count","early_restart","early_restart_pending"):
        diagnostic="Naive source join invocation started before drain" if case.startswith("early_restart") else "Naive source join ownership/count violation"
        run_case(mxu,env,"naive_source_join",case,"+CASE="+case,diagnostic)
    cases=[("minimum",1,mxu,1,0,0),("maximum",4,128,128,0,0),("n_tail",4,256,129,0,0),("near_max",4,128,127,0,0),("k_tail",4,128+mxu,33,0,0),("multi_tile",256,256,256,0,0),("original",4,512,512,0,0),("layout",4,256,129,1,1)]
    fsm_logs={}
    for name,m,k,n,q,t in cases:
        args=f"+M={m} +K={k} +N={n} +QROW={q} +WTRANS={t}"
        dest=run_case(mxu,env,"naive_meta_fsm",name,args)
        proc=subprocess.run(["python3",str(ROOT/"agent-tasks/source-join-ff-bw/verification/check_acc_stream.py"),str(dest/"sim.log"),"--m",str(m),"--k",str(k),"--n",str(n),"--mxu",str(mxu),"--qrow",str(q),"--wtrans",str(t)]+(["--acc"] if mxu==16 else []),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (dest/"oracle.json").write_text(proc.stdout)
        if proc.returncode:raise RuntimeError(proc.stdout)
        fsm_logs[name]=dest/"sim.log"
    for name,m,k,n,q,t in cases:
        if name not in ("minimum","maximum","n_tail","layout"):continue
        for retire in (0,1):
            args=f"+M={m} +K={k} +N={n} +QROW={q} +WTRANS={t} +SOURCE_DONE_AT_RETIRE={retire}"
            dest=run_case(mxu,env,"naive_meta_control",f"{name}_retire{retire}",args)
            def transcript(path):return [line for line in path.read_text().splitlines() if line.startswith(("CMD ","CLOSE "))]
            assert transcript(dest/"sim.log")==transcript(fsm_logs[name]),f"Integrated transcript differs: {dest}"
            (dest/"oracle.json").write_text(json.dumps(dict(status="pass",reference=str(fsm_logs[name]),scope="Exact CMD/CLOSE transcript equality with independently verified standalone FSM"),indent=2)+"\n")
print(f"PASS {len(rows)} VCS cases",flush=True)
