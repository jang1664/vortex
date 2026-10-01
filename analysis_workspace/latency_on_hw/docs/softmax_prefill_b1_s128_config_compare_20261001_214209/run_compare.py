from pathlib import Path
import concurrent.futures,hashlib,json,os,re,shlex,signal,subprocess,time
record=json.loads((Path(__file__).parent/'experiment.json').read_text())
out=Path(record['output']);source=Path(record['source']);repo=Path(record['repo'])
env=os.environ.copy()
for name in ('CONFIGS','PERF','DEBUG','SCOPE','PROFILE','GUI','VORTEX_HOME','VORTEX_RT_PATH','VORTEX_KN_PATH','VCS_SOCKET_PORT','FPGA_BIN_DIR','XRT_XCLBIN_PATH'):
    env.pop(name,None)
env.update(MAKEFLAGS=record['makeflags'],SOFTMAX_VARIANT=record['variant'],SIMLIB_DIR=str(repo/'build/vcs_simlib'),VCS_SIMLIB_DIR=str(repo/'build/vcs_simlib'),XILINX_IP_DIR=str(repo/'build_lmem_capacity_verify/sim/xrtsim_vcs/xilinx_ip'),PATH='/usr/bin:'+env['PATH'])

def run(index,name):
    build=source/f'build_{index}';folder=out/f'config_{index}'
    command=['ci/run_black.sh','xrt-vcs-sim','--app','softmax','--args',record['case']['args']]
    shell='set -e\nsource '+shlex.quote(str(source/'configs'/name))+'\n'+shlex.join(command)
    (folder/'command.sh').write_text('#!/bin/bash\n'+shell+'\n')
    print(f'START config_{index}: {name}',flush=True)
    start=time.monotonic();rc=None
    for attempt,limit in enumerate((300,1800),1):
        log=folder/f'run_attempt_{attempt}.log'
        with log.open('w') as stream:
            p=subprocess.Popen(['bash','-c',shell],cwd=build,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            (folder/'process.json').write_text(json.dumps({'pid':p.pid,'attempt':attempt,'timeout_seconds':limit,'started':time.time()})+'\n')
            try:rc=p.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGTERM)
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
                rc=124
        simlog=build/'sim/xrtsim_vcs/simv.log'
        if simlog.exists():
            (folder/f'simv_attempt_{attempt}.log').write_bytes(simlog.read_bytes())
        print(f'END config_{index} attempt {attempt}: rc={rc}',flush=True)
        if rc!=124:break
    text=log.read_text(errors='replace')
    perf=re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)',text)
    passed=rc==0 and 'PASSED' in text and bool(perf)
    result={'index':index,'config':name,'returncode':rc,'passed':passed,'seconds':round(time.monotonic()-start,3),'log':str(log),'build':str(build),'command':shell}
    if perf:result.update(instrs=int(perf[0][0]),cycles=int(perf[0][1]),ipc=float(perf[0][2]))
    kernel=build/'tests/regression/softmax/kernel.vxbin'
    if kernel.exists():result['kernel_sha256']=hashlib.sha256(kernel.read_bytes()).hexdigest()
    for file in ('u55c_model_manifest.json','compile.log'):
        p=build/'sim/xrtsim_vcs'/file
        if p.exists():(folder/file).write_bytes(p.read_bytes())
    (folder/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    futures=[pool.submit(run,i,name) for i,name in enumerate(record['configs'],1)]
    results=[f.result() for f in futures]
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
