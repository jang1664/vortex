#!/usr/bin/env python3
"""Measure M256 GEMM node cycles with perf class 3 in isolated VCS builds."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CONFIG_DIR = ROOT / 'agent-tasks/mxu-slr-port/verification/configs'
SOURCE_FILES = [ROOT / p for p in (
    'hw/rtl/core/gemm/VX_gemm_unit.sv',
    'hw/rtl/core/gemm/VX_gemm_ctrl.sv',
    'hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv',
    'runtime/stub/utils.cpp',
    'tests/regression/fpint_gemm_ffn_hw/main.cpp',
    'tests/regression/fpint_gemm_ffn_hw_naive/main.cpp')]


def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in SOURCE_FILES}


def execute(command, cwd, env, logfile, seconds):
    start = time.monotonic()
    with logfile.open('w') as stream:
        result = subprocess.run(
            ['timeout', '--signal=TERM', '--kill-after=10s', str(seconds), *command],
            cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    return result.returncode, round(time.monotonic() - start, 2)


def run(backend, slr):
    name = f'{backend}_slr{slr}'
    out = HERE / 'results' / name
    out.mkdir(parents=True, exist_ok=False)
    build = ROOT / f'build_mxu_perf3_{name}'
    build.mkdir(exist_ok=False)
    config = CONFIG_DIR / ('th32_c1_improve_m32_tcol32.sh' if backend == 'improve'
                           else 'th32_c1_naive_m32_tcol32.sh')
    tokens = subprocess.check_output(
        ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'config', str(config)],
        text=True).split()
    if backend == 'naive_noacc':
        tokens.remove('-DGEMM_NAIVE_USE_ACC_MEM')
    if slr:
        tokens.append('-DGEMM_SLR_PIPELINE')
    tokens.append('-DDISABLE_FSDB')
    env = os.environ.copy()
    for key in ('DEBUG', 'DEBUG_AXI', 'PERF'):
        env.pop(key, None)
    env.update(CONFIGS=' '.join(tokens), CC='/usr/bin/gcc', CXX='/usr/bin/g++',
               VCS_CPPFLAGS='-DDEBUG_LEVEL=0',
               THIRD_PARTY_DIR=str(ROOT / 'third_party'),
               SIMLIB_DIR=str(ROOT / 'build/vcs_simlib'),
               XILINX_IP_DIR=str(ROOT / 'build/sim/xrtsim_vcs/xilinx_ip'))
    source_hashes = hashes()
    configure = ['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                 f'--prefix={Path.home()}/tools/vortex']
    code, _ = execute(configure, build, env, out / 'configure.log', 300)
    if code:
        raise RuntimeError(f'{name}: configure failed: {code}')
    app = 'fpint_gemm_ffn_hw' if backend == 'improve' else 'fpint_gemm_ffn_hw_naive'
    command = [str(ROOT / 'ci/run_black.sh'), 'xrt-vcs-sim', '--app', app,
               '--args', '-m 256 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1', '--perf', '3']
    record = dict(variant=name, backend=backend, slr=slr, configure=configure,
                  commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  source_sha256=source_hashes, config=str(config),
                  config_sha256=hashlib.sha256(config.read_bytes()).hexdigest(),
                  configs=env['CONFIGS'], effective_perf_configs=env['CONFIGS']+' -DPERF_ENABLE',
                  command=command, build=str(build), attempts=[])
    for attempt, limit in enumerate((300, 1800), 1):
        assert hashes() == source_hashes, 'Source changed before run'
        log = out / f'attempt{attempt}.log'
        print(f'START {name} attempt={attempt} timeout={limit}', flush=True)
        code, duration = execute(command, build, env, log, limit)
        assert hashes() == source_hashes, 'Source changed during run'
        simlog = build / 'sim/xrtsim_vcs/simv.log'
        saved_simlog = out / f'attempt{attempt}.simv.log'
        if simlog.exists():
            shutil.copyfile(simlog, saved_simlog)
        text = log.read_text(errors='replace')
        diagnostics = text + (saved_simlog.read_text(errors='replace') if saved_simlog.exists() else '')
        counters = re.findall(r'PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)', text)
        compute = re.findall(r'PERF: compute_cycles=(\d+) stall_cycles=(\d+) mac_count=(\d+)', text)
        fatal = bool(re.search(r'Fatal:|Error-|^ERROR[: ]|Assertion.*fail|\$fatal', diagnostics, re.M))
        passed = code == 0 and 'PASSED' in text and not fatal and len(counters) == 1
        entry = dict(returncode=code, seconds=duration, passed=passed, fatal=fatal,
                     log=str(log), simlog=str(saved_simlog), timeout=limit)
        if counters:
            entry.update(zip(('jobs', 'total_cycles', 'busy_cycles'), map(int, counters[-1])))
        if compute:
            entry.update(zip(('compute_cycles', 'stall_cycles', 'mac_count'), map(int, compute[-1])))
        record['attempts'].append(entry)
        (out / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
        print(f'END {name} rc={code} pass={passed} counters={counters} seconds={duration}', flush=True)
        if code != 124:
            break
        if not re.search(r'Compiling|Parsing|g\+\+|gcc|V C S|cycles|vhdlan', diagnostics):
            break
    return record


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futures = [pool.submit(run, backend, slr)
                   for backend in ('improve', 'naive_acc', 'naive_noacc') for slr in (0, 1)]
        records = [f.result() for f in futures]
    (HERE / 'results' / 'summary.json').write_text(json.dumps(records, indent=2)+'\n')
    passed = sum(r['attempts'][-1]['passed'] for r in records)
    print(f'TOTAL {passed}/6 passed', flush=True)
    raise SystemExit(0 if passed == 6 else 1)
