from pathlib import Path
import json, os, subprocess, shlex, time, re, hashlib, shutil, signal

out = Path(__file__).resolve().parent
record = json.loads((out / 'experiment.json').read_text())
repo, build = Path(record['repo']), Path(record['build'])
env = os.environ.copy()
for name in ('CONFIGS', 'PERF', 'DEBUG', 'SCOPE', 'PROFILE', 'GUI', 'FSDB_DUMP',
             'VORTEX_HOME', 'VORTEX_RT_PATH', 'VORTEX_KN_PATH', 'VCS_SOCKET_PORT',
             'FPGA_BIN_DIR', 'XRT_XCLBIN_PATH', 'STARTUP_ADDR'):
    env.pop(name, None)
env.update(PATH='/usr/bin:' + env['PATH'], CC='/usr/bin/gcc', CXX='/usr/bin/g++',
           MAKEFLAGS='-j8', SIMLIB_DIR=str(repo / 'build/vcs_simlib'),
           VCS_SIMLIB_DIR=str(repo / 'build/vcs_simlib'),
           XILINX_IP_DIR=str(repo / 'build_lmem_capacity_verify/sim/xrtsim_vcs/xilinx_ip'))
(out / 'environment.json').write_text(json.dumps({k:env[k] for k in
    ('CC','CXX','MAKEFLAGS','SIMLIB_DIR','VCS_SIMLIB_DIR','XILINX_IP_DIR')}, indent=2) + '\n')
results = []
for key, cfg in zip(record['keys'], record['configs']):
    folder = out / key
    shell = 'set -e\nsource ' + shlex.quote(str(repo / 'configs' / cfg))
    shell += '\n' + shlex.join(['ci/run_black.sh', 'xrt-vcs-sim', '--app', record['app'], '--args', record['args']])
    (folder / 'command.sh').write_text('#!/bin/bash\n' + shell + '\n')
    assert (repo / 'configs' / cfg).read_bytes() == (folder / 'config.sh').read_bytes()
    print('START ' + key, flush=True)
    started = time.monotonic()
    with (folder / 'run.log').open('w') as log:
        process = subprocess.Popen(['bash', '-c', shell], cwd=build, env=env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        (folder / 'process.json').write_text(json.dumps({'pid': process.pid, 'started':time.time()}, indent=2) + '\n')
        timed_out = False
        try:
            rc = process.wait(timeout=record['first_check_seconds'])
        except subprocess.TimeoutExpired:
            simlog = build / 'sim/xrtsim_vcs/simv.log'
            check = {'seconds': round(time.monotonic()-started, 1),
                     'run_log_bytes': (folder/'run.log').stat().st_size,
                     'simv_log_bytes': simlog.stat().st_size if simlog.exists() else None}
            (folder / 'five_minute_checkpoint.json').write_text(json.dumps(check,indent=2)+'\n')
            print('CHECKPOINT '+key+' '+json.dumps(check),flush=True)
            try:
                rc = process.wait(timeout=record['max_seconds'] - record['first_check_seconds'])
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid,signal.SIGKILL);process.wait()
                rc = 124
    text = (folder/'run.log').read_text(errors='replace')
    perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)',text)
    consistent = bool(perf) and len({(a,b) for a,b,_ in perf}) == 1
    result = {'candidate':key,'config':cfg,'app':record['app'],'args':record['args'],
              'returncode':rc,'timed_out':timed_out,'passed':rc == 0 and 'PASSED' in text and consistent,
              'perf_values_consistent':consistent,'seconds':round(time.monotonic()-started,3)}
    if perf: result.update(instrs=int(perf[0][0]),cycles=int(perf[0][1]),ipc=float(perf[0][2]))
    kernel = build/'tests/regression'/record['app']/'kernel.vxbin'
    if kernel.exists():
        result['kernel_sha256'] = hashlib.sha256(kernel.read_bytes()).hexdigest()
        shutil.copy2(kernel,folder/'kernel.vxbin')
    for name in ('compile.log','simv.log','u55c_model_manifest.json','.simv_config','gen_hbm_config.json'):
        src = build/'sim/xrtsim_vcs'/name
        if src.exists(): shutil.copy2(src,folder/name)
    for name in ('u55c_model_manifest.json','hbm_model_config.json'):
        src=build/'runtime'/name
        if src.exists():shutil.copy2(src,folder/name)
    (folder/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    results.append(result)
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('END '+key+' '+json.dumps(result),flush=True)
    if not result['passed']:
        (out/'STATUS.yaml').write_text('status: failed\ncandidate: '+key+'\n')
        raise SystemExit(1)
(out/'STATUS.yaml').write_text('status: complete\nmode: xrt-vcs-sim\nbuild: build/\nexecution: sequential\nreference_checks: PASS / PASS\n')
