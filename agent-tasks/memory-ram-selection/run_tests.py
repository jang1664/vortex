#!/usr/bin/env python3
"""Configured VCS and xrt-vcs-sim verification for numeric RAM selectors."""
import concurrent.futures
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('verify_rtl', ROOT / 'tools/verify_rtl.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
SOURCES = ['hw/rtl/VX_config.vh', 'hw/rtl/mem/VX_local_mem.sv',
           'hw/rtl/mem/VX_tensor_mem_bank.sv', 'hw/rtl/core/gemm/VX_gemm_unit.sv',
           'hw/rtl/libs/VX_sp_ram.sv', 'hw/unittest/tensor_mem_bank/Makefile',
           'hw/unittest/tensor_mem_bank/vcs.mk',
           'hw/unittest/tensor_mem_bank/tb_VX_tensor_mem_bank.sv']
LABEL = ''


def hashes():
    return {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in SOURCES}


def execute(cmd, cwd, env, log, seconds):
    start = time.monotonic()
    with log.open('w') as stream:
        p = subprocess.run(['timeout', '--signal=TERM', '--kill-after=10s', str(seconds), *cmd],
                           cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    return p.returncode, round(time.monotonic()-start, 2)


def run(kind, backend, value, synthesis=False):
    name = f'{kind}_{backend}_{"default" if value is None else value}' + ('_synth' if synthesis else '')
    if LABEL:
        name = LABEL + '_' + name
    out = HERE/'results'/name
    out.mkdir(parents=True, exist_ok=False)
    build = ROOT/f'build_ram_select_{name}'
    build.mkdir(exist_ok=False)
    config = HERE/'configs'/f'th32_c1_{backend}_m32_tcol32.sh'
    defines = subprocess.check_output(['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"',
                                      'config', str(config)], text=True).split()
    if value is not None:
        defines += [f'-D{m}_USE_URAM={value}' for m in ('LMEM', 'GEMM_ACC', 'TMEM')]
    if synthesis:
        defines.append('-DSYNTHESIS')
    if kind == 'kernel':
        defines += ['-DGEMM_SLR_PIPELINE', '-DDISABLE_FSDB']
    env = os.environ.copy()
    for key in ('DEBUG', 'DEBUG_AXI', 'PERF'):
        env.pop(key, None)
    env.update(CONFIGS=' '.join(defines), CC='/usr/bin/gcc', CXX='/usr/bin/g++',
               VCS_CPPFLAGS='-DDEBUG_LEVEL=0', THIRD_PARTY_DIR=str(ROOT/'third_party'),
               SIMLIB_DIR=str(ROOT/'build/vcs_simlib'),
               XILINX_IP_DIR=str(ROOT/'build/sim/xrtsim_vcs/xilinx_ip'))
    before = hashes()
    configure = ['../configure', '--xlen=64', '--tooldir=/opt/vortex', f'--prefix={Path.home()}/tools/vortex']
    code, _ = execute(configure, build, env, out/'configure.log', 300)
    if code:
        raise RuntimeError(f'{name} configure failed: {code}')
    if kind == 'unit':
        cmd = ['python3', str(ROOT/'tools/verify_rtl.py'), 'unittest', '--path',
               str(build/'hw/unittest/tensor_mem_bank'), '--sim', 'vcs']
        sim = build/'hw/unittest/tensor_mem_bank/logs/sim.log'
    else:
        app = 'fpint_gemm_ffn_hw' if backend == 'improve' else 'fpint_gemm_ffn_hw_naive'
        cmd = [str(ROOT/'ci/run_black.sh'), 'xrt-vcs-sim', '--app', app,
               '--args', '-m 256 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1']
        sim = build/'sim/xrtsim_vcs/simv.log'
    result = dict(name=name, kind=kind, backend=backend, value=value, synthesis_rtl=synthesis,
                  source_sha256=before, configs=env['CONFIGS'], config=str(config),
                  configure=configure, command=cmd, build=str(build), attempts=[])
    for attempt, seconds in enumerate((300, 1800), 1):
        assert hashes() == before, 'Sources changed before run'
        print(f'START {name} attempt={attempt}', flush=True)
        log=out/f'attempt{attempt}.log'
        code,duration=execute(cmd, build, env, log, seconds)
        assert hashes() == before, 'Sources changed during run'
        text=log.read_text(errors='replace')
        if sim.exists():
            shutil.copyfile(sim, out/f'attempt{attempt}.sim.log')
            text+='\n'+sim.read_text(errors='replace')
        fatal=bool(re.search(r'Fatal:|Error-|^ERROR[: ]|Assertion.*fail|\$fatal',text,re.M))
        passed=code==0 and verify.check_pass(text) and not fatal
        result['attempts'].append(dict(returncode=code,seconds=duration,passed=passed,
                                       log=str(log),fatal=fatal))
        (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(f'END {name} rc={code} pass={passed} seconds={duration}',flush=True)
        if code !=124 or not re.search(r'Compiling|Parsing|gcc|g\+\+|V C S',text):
            break
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('all', 'unit', 'kernel'), default='all')
    parser.add_argument('--label', default='', help='Unique prefix for fresh builds and evidence')
    args = parser.parse_args()
    LABEL = args.label
    cases=[('unit','improve',None,False), ('unit','improve',0,False),
           ('unit','improve',1,False), ('unit','improve',0,True), ('unit','improve',1,True)]
    cases += [('kernel',backend,value,False) for backend in ('improve','naive') for value in (0,1)]
    cases = [c for c in cases if args.suite == 'all' or c[0] == args.suite]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        records=list(pool.map(lambda args: run(*args),cases))
    summary_name = f'{LABEL}_summary.json' if LABEL else 'summary.json'
    (HERE/'results'/summary_name).write_text(json.dumps(records,indent=2)+'\n')
    passed=sum(r['attempts'][-1]['passed'] for r in records)
    print(f'TOTAL {passed}/{len(cases)} PASS',flush=True)
    raise SystemExit(0 if passed==len(cases) else 1)
