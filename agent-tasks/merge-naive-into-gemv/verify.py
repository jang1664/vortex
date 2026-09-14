#!/usr/bin/env python3
"""Reproduce the merge regression with separate configured builds and evidence."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BASE = ROOT / 'build_merge_naive_baseline_source'
EXEC = TASK / 'execution'
REUSE_BUILD = False
ONLY_CASES = None
PROFILES = {
    'improve_off': ('improve_th16_tcol16_m16_t8_bigmem_all_bram.sh', False, False),
    'improve_on': ('improve_th16_tcol16_m16_t8_bigmem_all_bram.sh', True, False),
    'l16_off': ('naive_th16_tcol16_m16_L16_bigmem_all_bram_base.sh', False, False),
    'l16_on': ('naive_th16_tcol16_m16_L16_bigmem_all_bram.sh', True, False),
    'l32_off': ('naive_th16_tcol16_m16_L32_bigmem_all_bram.sh', False, False),
    **{f'd256_{slr}_{acc}': ('naive_th16_tcol16_m16_L32_bigmem_all_bram_D256.sh',
                            slr == 'on', acc == 'acc')
       for slr in ['off', 'on'] for acc in ['lmem', 'acc']},
}


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def environment(source, profile):
    config, slr, acc = PROFILES[profile]
    raw = subprocess.check_output(['bash', '-c', 'set -e; source "$1"; env -0',
                                   'bash', str(source / 'configs' / config)], cwd=source)
    env = dict(s.split('=', 1) for s in raw.decode().split('\0') if '=' in s)
    flags = [s for s in shlex.split(env['CONFIGS'])
             if s not in ['-DGEMM_SLR_PIPELINE', '-DGEMM_NAIVE_USE_ACC_MEM']]
    if slr:
        flags.append('-DGEMM_SLR_PIPELINE')
    if acc:
        flags.append('-DGEMM_NAIVE_USE_ACC_MEM')
    env['CONFIGS'] = ' '.join(flags)
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'FPGA_BIN_DIR',
                'XRT_XCLBIN_PATH', 'MAKEFLAGS', 'MFLAGS', 'MAKELEVEL']:
        env.pop(key, None)
    env.update(CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0',
               PATH='/usr/bin:' + env['PATH'])
    return env


def configure(source, build, env, out):
    if REUSE_BUILD and build.exists():
        assert (build / 'config.mk').is_file(), 'Cannot reuse an unconfigured build'
        assert str(source) in (build / 'config.mk').read_text(), 'Build source mismatch'
        (out / 'configure.log').write_text(f'Reusing configured build: {build}\n')
        return
    build.mkdir(exist_ok=False)
    command = ['../configure', '--xlen=64', '--tooldir=/opt/vortex',
               f'--prefix={Path.home()}/tools/vortex']
    with (out / 'configure.log').open('w') as log:
        subprocess.run(command, cwd=build, env=env, stdout=log,
                       stderr=subprocess.STDOUT, check=True)


def hashes(source):
    files = subprocess.check_output(['rg', '--files', 'hw/rtl', 'configs',
        'sim/xrtsim_vcs', 'tests/regression/fpint_gemm_ffn_hw',
        'tests/regression/fpint_gemm_ffn_hw_naive', 'tests/common'],
        cwd=source, text=True).splitlines()
    return {f: hashlib.sha256((source / f).read_bytes()).hexdigest()
            for f in sorted(files) if (source / f).is_file()}


def blackbox(item):
    revision, profile = item
    label = revision + '_' + profile
    out = EXEC / label
    out.mkdir(exist_ok=False)
    source = BASE if revision == 'baseline' else ROOT
    build = source / ('build_merge_' + label)
    env = environment(source, profile)
    env['CONFIGS'] += ' -DGEMM_LATENCY_OBSERVER -DDISABLE_FSDB'
    # Existing generated IP and compiled vendor libraries are immutable inputs.
    ip = ROOT / 'build_naive_slr_candidate_source/build_improve_on/sim/xrtsim_vcs/xilinx_ip'
    env['MAKEFLAGS'] = (f'VCS_P2_FLAGS=-debug_access+all SIMLIB_DIR={ROOT}/build/vcs_simlib '
                       f'XILINX_IP_DIR={ip} XILINX_IP_GEN_TCL={ROOT}/hw/scripts/xilinx_ip_gen.tcl')
    configure(source, build, env, out)
    help_result = subprocess.run(['ci/run_black.sh', '--help'], cwd=build, env=env,
                                 capture_output=True, text=True)
    (out / 'wrapper_help.txt').write_text(help_result.stdout + help_result.stderr)
    before = hashes(source)
    save(out / 'source_hashes.json', before)
    improve = profile.startswith('improve')
    app = 'fpint_gemm_ffn_hw' + ('' if improve else '_naive')
    cases = [(f'm{m}', m, 512, 512, 0, 0, 1, False) for m in [4, 256]]
    if profile.startswith('d256_on'):
        cases += [(f'tag_w{w}_d{d}', 16, 64, 64, w, d, 2, True)
                  for w in [0, 1] for d in [0, 1]]
    if ONLY_CASES:
        cases = [case for case in cases if case[0] in ONLY_CASES]
        assert cases, 'No selected cases for this profile'
    records = []
    for name, m, n, k, w, d, repeat, tagged in cases:
        case = out / name
        case.mkdir()
        args = f'-m {m} -k {k} -n {n} -q 32 -t {w} -d {d} -r {repeat}'
        if tagged:
            args += ' --tagged'
        command = ['timeout', '--signal=TERM', '--kill-after=30', '7200',
                   'ci/run_black.sh', 'xrt-vcs-sim', '--perf', '3', '--app', app, '--args', args]
        manifest = dict(profile=profile, revision=revision, build=str(build),
                        configs=env['CONFIGS'], makeflags=env['MAKEFLAGS'], command=command,
                        start=datetime.now().isoformat(), source=str(source), state='running')
        save(case / 'manifest.json', manifest)
        print('START', label, name, flush=True)
        with (case / 'wrapper.log').open('w') as log:
            rc = subprocess.run(command, cwd=build, env=env, stdout=log,
                                stderr=subprocess.STDOUT).returncode
        for filename in ['simv.log', 'u55c_model_manifest.json']:
            src = build / 'sim/xrtsim_vcs' / filename
            if src.exists():
                shutil.copy2(src, case / filename)
        wrapper = (case / 'wrapper.log').read_text(errors='replace')
        sim = (case / 'simv.log').read_text(errors='replace') if (case / 'simv.log').exists() else ''
        gemm = [int(x) for x in re.findall(r'^GEMM_LATENCY_DONE .*?\bL_gemm=(\d+)', sim, re.M)]
        core = [int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),', wrapper, re.M)]
        spec = importlib.util.spec_from_file_location('verifier', ROOT / 'tools/verify_rtl.py')
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        changed = before != hashes(source)
        passed = (rc == 0 and verifier.check_pass(wrapper + '\n' + sim)
                  and not verifier.has_strict_failure(wrapper + '\n' + sim)
                  and len(gemm) == repeat and len(core) == 1 and not changed)
        manifest.update(state='finished', end=datetime.now().isoformat(), returncode=rc,
                        passed=passed, gemm_cycles=gemm, core_cycles=core, source_changed=changed)
        save(case / 'manifest.json', manifest)
        records.append(dict(case=name, **manifest))
        save(out / 'results.json', records)
        print('DONE', label, name, passed, gemm, core, flush=True)
        if not passed:
            return False
    return True


def unit(item):
    name, profile, target, extras = item
    out = EXEC / name
    out.mkdir(exist_ok=False)
    build = ROOT / ('build_merge_' + name)
    env = environment(ROOT, profile)
    configure(ROOT, build, env, out)
    command = ['make', '-C', str(build / 'hw/unittest' / target),
               'SIM_EXEC=vcs', *extras, 'sim']
    save(out / 'manifest.json', dict(command=command, configs=env['CONFIGS'], build=str(build)))
    print('START', name, flush=True)
    with (out / 'wrapper.log').open('w') as log:
        rc = subprocess.run(['timeout', '--kill-after=30', '900', *command], cwd=build,
                            env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    log = (out / 'wrapper.log').read_text(errors='replace')
    passed = rc == 0 and bool(re.search(r'\bPASS(?:ED)?\b', log)) and not re.search(r'(^Fatal:|^Error-|\bFAILED\b)', log, re.M)
    result = dict(name=name, profile=profile, command=command, configs=env['CONFIGS'],
                  passed=passed, returncode=rc, build=str(build))
    save(out / 'result.json', result)
    print('DONE', name, passed, flush=True)
    return passed


def main():
    global EXEC, REUSE_BUILD, ONLY_CASES
    parser = argparse.ArgumentParser()
    parser.add_argument('suite', choices=['blackbox', 'unit'])
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--only', nargs='*')
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--reuse-build', action='store_true')
    parser.add_argument('--cases', nargs='+')
    args = parser.parse_args()
    REUSE_BUILD = args.reuse_build
    ONLY_CASES = args.cases
    if args.output_root:
        EXEC = args.output_root.resolve()
        EXEC.mkdir(parents=True, exist_ok=True)
    if args.suite == 'blackbox':
        items = [('baseline', p) for p in ['improve_off', 'improve_on']]
        items += [('candidate', p) for p in PROFILES]
        if args.only:
            items = [x for x in items if '_'.join(x) in args.only]
        fn = blackbox
    else:
        items = [('unit_bridge_' + p, p, 'naive_dma_slr', [])
                 for p in ['l16_on', 'd256_on_lmem']]
        items += [('unit_dma_' + p + ('_wide' if p.startswith('d256') else ''), p, 'dma_node',
                   ['CONFIGS=' + environment(ROOT, p)['CONFIGS'] + ' -DNAIVE_DMA_SLR_TEST',
                    'PARAMS=-pvalue+tb_VX_dma_node.TB_DCACHE_NUM_LANES=' + ('4' if p.startswith('d256') else '1')])
                  for p in ['l16_on', 'd256_on_lmem']]
        items += [('unit_gemm_' + p, p, 'gemm_unit_v2', [])
                  for p in ['improve_off', 'd256_off_lmem', 'd256_off_acc']]
        items += [('unit_lmem32', 'd256_off_acc', 'lmem_dma_misal',
                   ['TB_BUS_BYTES=32', 'RD_PREFETCH_DEPTH=4', 'REORDER_RESPONSES=1',
                    'GEMM_REQ_BACKPRESSURE=1', 'ENABLE_MISALIGN=1', 'GENERALIZED=0'])]
        if args.only:
            items = [x for x in items if x[0] in args.only]
        fn = unit
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(fn, items))
    return 0 if all(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
