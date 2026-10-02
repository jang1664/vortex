from pathlib import Path
import os,json,subprocess,time,shlex,re,hashlib,signal,shutil

out=Path(__file__).resolve().parent
record=json.loads((out/'experiment.json').read_text())
repo,build=Path(record['repo']),Path(record['build'])
env=os.environ.copy()
for k in ('CONFIGS','PERF','DEBUG','SCOPE','PROFILE','GUI','FSDB_DUMP','VORTEX_HOME',
          'VORTEX_RT_PATH','VORTEX_KN_PATH','VCS_SOCKET_PORT','FPGA_BIN_DIR',
          'XRT_XCLBIN_PATH','XRT_DEVICE_INDEX','XRT_DEVICE_BDF','XRT_INI_PATH',
          'STARTUP_ADDR','ITYPE','OTYPE','ACC_TYPE','VX_KERNEL','BENCH'):
    env.pop(k,None)
for k in list(env):
    if k.endswith('_VARIANT') and k not in record['variants']:env.pop(k,None)
env.update(record['variants'])
env.update(PATH='/usr/bin:'+env['PATH'],CC='/usr/bin/gcc',CXX='/usr/bin/g++',MAKEFLAGS='-j4')
(out/'environment.json').write_text(json.dumps({k:env[k] for k in (*record['variants'],'CC','CXX','MAKEFLAGS')},indent=2)+'\n')
results=[]
for i,w in enumerate(record['workloads'],1):
    folder=out/w['candidate']/w['app'];folder.mkdir(exist_ok=True)
    command=['ci/run_black.sh','hw','--fpga-bin',w['alias'],'--app',w['app'],'--args',w['args']]
    (folder/'command.sh').write_text('#!/bin/bash\nset -e\ncd '+shlex.quote(str(build))+'\n'+shlex.join(command)+'\n')
    print(f"START {i}/{len(record['workloads'])} {w['candidate']} {w['app']}",flush=True)
    begin=time.monotonic();timed_out=False
    with (folder/'run.log').open('w') as stream:
        p=subprocess.Popen(command,cwd=build,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        (folder/'process.json').write_text(json.dumps({'pid':p.pid,'started':time.time()},indent=2)+'\n')
        try:rc=p.wait(timeout=record['max_seconds'])
        except subprocess.TimeoutExpired:
            timed_out=True
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
            rc=124
    log=(folder/'run.log').read_text(errors='replace')
    passed=rc==0 and bool(re.search(r'\bPASSED\b',log))
    r=dict(w,returncode=rc,passed=passed,timed_out=timed_out,seconds=round(time.monotonic()-begin,3),command=shlex.join(command))
    perf=re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)',log)
    if perf:r.update(instrs=int(perf[-1][0]),cycles=int(perf[-1][1]),ipc=float(perf[-1][2]))
    device=re.search(r'HW XRT_DEVICE_INDEX=(\S+) XRT_DEVICE_BDF=(\S+)',log)
    if device:r.update(device_index=device[1],device_bdf=device[2])
    kernel=build/'tests/regression'/w['app']/'kernel.vxbin'
    if kernel.exists():r['kernel_sha256']=hashlib.sha256(kernel.read_bytes()).hexdigest()
    if not passed:
        r['error_lines']=[l for l in log.splitlines() if len(l)<350 and re.search(r'error|failed|mismatch|invalid|timeout|fatal',l,re.I)][-16:]
    (folder/'result.json').write_text(json.dumps(r,indent=2)+'\n');results.append(r)
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    (out/'STATUS.yaml').write_text(f"status: running\nmode: hw\ncompleted: {len(results)}\nplanned: {len(record['workloads'])}\npassed: {sum(x['passed'] for x in results)}\n")
    print('END '+w['candidate']+' '+w['app']+' '+json.dumps(r),flush=True)
(out/'STATUS.yaml').write_text(f"status: complete\nmode: hw\ncompleted: {len(results)}\nplanned: {len(record['workloads'])}\npassed: {sum(x['passed'] for x in results)}\nfailed: {sum(not x['passed'] for x in results)}\n")
