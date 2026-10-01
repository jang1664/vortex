from pathlib import Path
import concurrent.futures
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import time

record = json.loads((Path(__file__).parent / 'experiment.json').read_text())
out = Path(record['output'])
source = Path(record['source'])
repo = Path(record['repo'])
env = os.environ.copy()
for name in ('CONFIGS', 'PERF', 'DEBUG', 'SCOPE', 'PROFILE', 'GUI',
             'VORTEX_HOME', 'VORTEX_RT_PATH', 'VORTEX_KN_PATH',
             'VCS_SOCKET_PORT', 'FPGA_BIN_DIR', 'XRT_XCLBIN_PATH'):
    env.pop(name, None)
env.update(record['variants'])
env.update(MAKEFLAGS=record['makeflags'],
           SIMLIB_DIR=str(repo / 'build/vcs_simlib'),
           VCS_SIMLIB_DIR=str(repo / 'build/vcs_simlib'),
           XILINX_IP_DIR=str(repo / 'build_lmem_capacity_verify/sim/xrtsim_vcs/xilinx_ip'),
           PATH='/usr/bin:' + env['PATH'])


def run_workload(config, workload):
    build = Path(config['build'])
    folder = Path(config['output']) / workload['id']
    folder.mkdir(exist_ok=True)
    command = ['ci/run_black.sh', 'xrt-vcs-sim', '--app', workload['app'],
               '--args', workload['args']]
    if workload.get('configs_extra'):
        command += ['--configs-extra', workload['configs_extra']]
    config_path = workload.get('config_path', str(source / 'configs' / config['config']))
    shell = 'set -e\nsource ' + shlex.quote(config_path)
    shell += '\n' + shlex.join(command)
    (folder / 'command.sh').write_text('#!/bin/bash\n' + shell + '\n')
    print(f"START {config['key']} {workload['id']}", flush=True)
    start = time.monotonic()
    log = folder / 'run.log'
    with log.open('w') as stream:
        process = subprocess.Popen(['bash', '-c', shell], cwd=build, env=env,
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        (folder / 'process.json').write_text(json.dumps({
            'pid': process.pid, 'started': time.time(),
            'first_check_seconds': record['first_check_seconds'],
            'max_seconds': record['max_seconds'],
        }, indent=2) + '\n')
        timed_out = False
        try:
            rc = process.wait(timeout=record['first_check_seconds'])
        except subprocess.TimeoutExpired:
            checkpoint = {
                'elapsed_seconds': round(time.monotonic() - start, 1),
                'run_log_bytes': log.stat().st_size,
            }
            simlog = build / 'sim/xrtsim_vcs/simv.log'
            if simlog.exists():
                checkpoint['simv_log_bytes'] = simlog.stat().st_size
            (folder / 'five_minute_checkpoint.json').write_text(
                json.dumps(checkpoint, indent=2) + '\n')
            print(f"CHECKPOINT {config['key']} {workload['id']}: "
                  + json.dumps(checkpoint), flush=True)
            try:
                rc = process.wait(timeout=record['max_seconds']
                                  - record['first_check_seconds'])
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                rc = 124
    log_text = log.read_text(errors='replace')
    perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)', log_text)
    consistent = bool(perf) and len({(a, b) for a, b, _ in perf}) == 1
    passed = rc == 0 and 'PASSED' in log_text and consistent
    result = {
        'key': config['key'], 'candidate': config['candidate'],
        'version': config['version'], 'config': config['config'],
        'alias': config['alias'], 'workload': workload,
        'returncode': rc, 'passed': passed, 'timed_out': timed_out,
        'seconds': round(time.monotonic() - start, 3),
        'build': str(build), 'log': str(log), 'command': shell,
        'perf_values_consistent': consistent,
    }
    if perf:
        result.update(instrs=int(perf[0][0]), cycles=int(perf[0][1]),
                      ipc=float(perf[0][2]))
    kernel = build / 'tests/regression' / workload['app'] / 'kernel.vxbin'
    if kernel.exists():
        result['kernel_sha256'] = hashlib.sha256(kernel.read_bytes()).hexdigest()
    for name in ('u55c_model_manifest.json', 'compile.log', 'simv.log'):
        path = build / 'sim/xrtsim_vcs' / name
        if path.exists():
            shutil.copy2(path, folder / name)
    (folder / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"END {config['key']} {workload['id']}: "
          f"rc={rc}, passed={passed}, cycles={result.get('cycles')}, "
          f"seconds={result['seconds']}", flush=True)
    return result


folder=out/"dma_port_diagnosis"
build=source/"build_dma1_diagnostic"
with (folder/"configure.log").open("w") as f:
    subprocess.run(["../configure","--xlen=64","--tooldir=/opt/vortex","--prefix=/home/jaeyongjang/tools/vortex"],cwd=build,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
cfg={'key': 'C3_dma1', 'candidate': 'C3', 'version': 'dma1_diagnostic', 'config': 'naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh', 'alias': None, 'build': '/tmp/vortex_vector_compare_b5azyy67/source/build_dma1_diagnostic', 'output': '/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c1_c4_softmax_quant_compare_20261002_002513/dma_port_diagnosis'}
results=[]
results.append(run_workload(cfg,{'id': 'quant_v', 'app': 'kv_cache_quant_w4a16', 'args': '-k 128 -n 128 -q 32 -d 1 -t 0 --quant-mode spinquant_signed_symmetric', 'config_path': '/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c1_c4_softmax_quant_compare_20261002_002513/dma_port_diagnosis/config_dma1.sh'}))
results.append(run_workload(cfg,{'id': 'softmax', 'app': 'softmax', 'args': '-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1', 'config_path': '/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/analysis_workspace/latency_on_hw/docs/c1_c4_softmax_quant_compare_20261002_002513/dma_port_diagnosis/config_dma1.sh'}))
(folder/"results.json").write_text(json.dumps(results,indent=2)+"\n")
