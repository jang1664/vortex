#!/usr/bin/env python3
"""Run rev6 C3/C4 in separate configured trees; keep per-case evidence."""
import argparse
import concurrent.futures, datetime, hashlib, json, os, shutil, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[5]
OUT = ROOT / "analysis_workspace/latency/docs/perf_rev6"
CASES = [
    dict(id="small", m=16,n=32,k=32,q=32,t=0,d=0),
    dict(id="llama3_kv_decode",m=1,n=1024,k=4096,q=32,t=0,d=0),
    dict(id="llama3_attention_decode",m=4,n=1025,k=128,q=128,t=1,d=0),
    dict(id="llama2_ffn_decode",m=1,n=11008,k=4096,q=32,t=0,d=0),
    dict(id="llama3_kv_decode_m4",m=4,n=1024,k=4096,q=32,t=0,d=0),
    dict(id="llama2_ffn_decode_m4",m=4,n=11008,k=4096,q=32,t=0,d=0),
]
CONFIGS = {"c3":"naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3", "c4":"improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp"}
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def run(candidate):
    build = ROOT / f"build_latency_perf_{candidate}_rev6"
    app = "fpint_gemm_ffn_hw_naive" if candidate=="c3" else "fpint_gemm_ffn_hw"
    for case in CASES:
        key=f"{candidate}_{case['id']}"
        args=" ".join(f"-{x} {case[x]}" for x in ['m','n','k','q','t','d'])
        cmd=f"source ../configs/{CONFIGS[candidate]}.sh\nexport CC=/usr/bin/gcc CXX=/usr/bin/g++\ntimeout {TIMEOUT} ci/run_black.sh xrt-vcs-sim --app {app} --args '{args}' --perf 3 --configs-extra '-DDISABLE_FSDB'"
        record=dict(candidate=candidate,case=case,app=app,command=cmd,started=datetime.datetime.now().isoformat(),status="running",config_sha256=digest(ROOT/f"configs/{CONFIGS[candidate]}.sh"),monitor_sha256=digest(OUT/'tools/fine_monitor.sv'))
        record['source_head']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        record['source_sha256']={str(p.relative_to(ROOT)):digest(p) for p in [
            ROOT/'hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv',
            ROOT/'hw/rtl/core/gemm/VX_gemm_compute_core.sv',
            ROOT/f'tests/regression/{app}/main.cpp',
            ROOT/f'tests/regression/{app}/kernel.cpp',
            ROOT/'tests/regression/fpint_gemm_ffn_hw/test_vectors.h']}
        status=OUT/'raw'/f"{key}.json"
        status.write_text(json.dumps(record,indent=2))
        print(f"START {key}",flush=True)
        begin=time.monotonic()
        with (OUT/'raw'/f"{key}.log").open('w') as log:
            result=subprocess.run(['/bin/bash','-c',cmd],cwd=build,stdout=log,stderr=subprocess.STDOUT)
        record['elapsed_seconds']=time.monotonic()-begin
        record['returncode']=result.returncode
        passed=any(line.strip()=='PASSED' for line in (OUT/'raw'/f"{key}.log").open())
        record['status']='passed' if result.returncode==0 and passed else 'failed'
        for src,dest in [('simv.log',f'{key}.simv.log'),('u55c_model_manifest.json',f'{key}.model.json')]:
            source=build/'sim/xrtsim_vcs'/src
            if source.exists():shutil.copy2(source,OUT/'raw'/dest)
        status.write_text(json.dumps(record,indent=2))
        print(f"END {key} {record['status']} {record['elapsed_seconds']:.1f}s",flush=True)
        if record['status']!='passed':break
if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--case',action='append')
    parser.add_argument('--candidate',action='append',choices=['c3','c4'])
    parser.add_argument('--timeout',type=int,default=1800)
    options=parser.parse_args()
    (OUT/'raw').mkdir(parents=True,exist_ok=True)
    TIMEOUT=options.timeout
    if options.case:CASES=[c for c in CASES if c['id'] in options.case]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(run,options.candidate or ['c3','c4']))
