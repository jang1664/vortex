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


def task(item):
    cfg, work = item
    with (Path(cfg["output"])/"configure.log").open("w") as stream:
        subprocess.run(["../configure","--xlen=64","--tooldir=/opt/vortex","--prefix=/home/jaeyongjang/tools/vortex"],cwd=cfg["build"],env=env,stdout=stream,stderr=subprocess.STDOUT,check=True)
    return run_workload(cfg,work)

configs = [({'key': 'ports2_original', 'candidate': 'C3', 'version': 'ports2_original', 'config': 'naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh', 'alias': None, 'build': '/tmp/vortex_c3_dma_debug_huuv2de0/source/build_ports2_original', 'output': '/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-dma-ports2-debug-20261001_233758/ports2_original'}, {'id': 'gemm_naive', 'app': 'fpint_gemm_ffn_hw_naive', 'args': '-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1', 'configs_extra': '-DDBG_TRACE_DMA_COMPARE'}), ({'key': 'ports2_reorder', 'candidate': 'C3', 'version': 'ports2_reorder', 'config': 'naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh', 'alias': None, 'build': '/tmp/vortex_c3_dma_debug_huuv2de0/source/build_ports2_reorder', 'output': '/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-dma-ports2-debug-20261001_233758/ports2_reorder'}, {'id': 'gemm_naive', 'app': 'fpint_gemm_ffn_hw_naive', 'args': '-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1', 'configs_extra': '-DDBG_TRACE_DMA_COMPARE -DDMA_SPLIT_RSP_REORDER=1'})]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    results=list(executor.map(task,configs))
(out/"results.json").write_text(json.dumps(results,indent=2)+"\n")
