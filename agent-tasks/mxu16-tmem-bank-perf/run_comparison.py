#!/usr/bin/env python3
"""Measure the class-3 GEMM counter with two supported MXU16 bank profiles."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
CONFIG = ROOT / 'configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def save(path, obj):
    path.write_text(json.dumps(obj, indent=2) + '\n')

def profile(banks, args):
    build = ROOT / f'build_mxu16_bank_perf_b{banks}'
    out = TASK / f'b{banks}'
    if not args.resume:
        build.mkdir(exist_ok=False)
        out.mkdir(exist_ok=False)
        with (out / 'configure.log').open('w') as log:
            subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                            '--prefix=' + os.environ['HOME'] + '/tools/vortex'],
                           cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True)
    raw = subprocess.check_output(['bash', '-c', 'source "$1"; env -0',
                                   'bash', str(CONFIG)], cwd=ROOT)
    env = dict(s.split('=', 1) for s in raw.decode().split('\0') if '=' in s)
    defines = env['CONFIGS'].split()
    defines = [d for d in defines if not d.startswith(('-DNUM_TMEM_BANKS=', '-DNUM_DMA_CHANNELS='))]
    defines += [f'-DNUM_TMEM_BANKS={banks}', f'-DNUM_DMA_CHANNELS={banks // 2}']
    env['CONFIGS'] = ' '.join(defines)
    env.update(PATH='/usr/bin:' + env['PATH'], CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0')
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'VCS_SIMV_FLAGS', 'XRT_XCLBIN_PATH', 'FPGA_BIN_DIR']:
        env.pop(key, None)
    sources = {str(p.relative_to(ROOT)): digest(p) for p in (ROOT / 'hw/rtl').rglob('*')
               if p.suffix in ('.sv', '.v', '.vh')}
    manifest = {'started': datetime.now().isoformat(), 'CONFIGS': env['CONFIGS'],
                'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'build': str(build), 'banks': banks, 'dma_channels': banks // 2,
                'bank_bytes': 32768, 'external_hbm_ports': 8, 'k': args.k, 'n': args.n,
                'repeats': args.repeats, 'source_sha256': sources,
                'memory_environment': {k: v for k, v in env.items() if k.startswith(('DRAM_', 'CACHE_'))},
                'measurement': 'PERF class3 GEMM total_cycles; no --debug, C2 retained'}
    if args.resume:
        original_manifest = json.loads((out / 'manifest.json').read_text())
        for key in ['CONFIGS', 'head', 'k', 'n', 'repeats', 'source_sha256', 'memory_environment']:
            if original_manifest[key] != manifest[key]:
                raise RuntimeError(f'Resume configuration changed: {key}')
    else:
        save(out / 'manifest.json', manifest)
    results = []
    sim_identity = (json.loads((out / 'simulator_identity.json').read_text())
                    if args.resume else None)
    for m in [1, 4, 256]:
        for repeat in range(args.repeats):
            case = out / f'm{m}_r{repeat}'
            existing = case.exists()
            if not existing:
                case.mkdir()
            command = ['timeout', '300' if m != 256 else '1800', './ci/run_black.sh',
                       'xrt-vcs-sim', '--perf', '3', '--app', 'fpint_gemm_ffn_hw',
                       '--args', f'-m {m} -k {args.k} -n {args.n} -q 32 -d 0 -t 0 -r 1']
            if existing:
                if not args.resume:
                    raise RuntimeError(f'Existing case: {case}')
                rc = json.loads((case / 'result.json').read_text())['returncode']
                if rc:
                    raise RuntimeError(f'Cannot reuse failed execution: {case}')
                if not (case / 'result_initial.json').exists():
                    shutil.copy2(case / 'result.json', case / 'result_initial.json')
            else:
                save(case / 'command.json', {'argv': command, 'cwd': str(build), 'CONFIGS': env['CONFIGS']})
                print(f'START banks={banks} M={m} repeat={repeat}', flush=True)
                with (case / 'wrapper.log').open('w') as log:
                    rc = subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                original = build / 'sim/xrtsim_vcs/simv.log'
                if original.exists():
                    shutil.copy2(original, case / 'simv.log')
            if not (out / 'compile.log').exists() and (build / 'sim/xrtsim_vcs/compile.log').exists():
                shutil.copy2(build / 'sim/xrtsim_vcs/compile.log', out / 'compile.log')
            metrics = None
            passed = False
            errors = []
            for name in ['wrapper.log', 'host.log', 'simv.log']:
                if not (case / name).exists():
                    continue
                with (case / name).open(errors='replace') as stream:
                    for line in stream:
                        passed |= name == 'wrapper.log' and line.strip() == 'PASSED'
                        match = re.search(r'PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)', line)
                        if name == 'wrapper.log' and match:
                            metrics = dict(zip(['jobs', 'total_cycles', 'busy_cycles'], map(int, match.groups())))
                        if re.search(r'Fatal:|FATAL|Mismatch\[|\bFAILED\b|^ERROR:', line) and len(errors) < 20:
                            errors.append(line.strip())
            simv = build / 'sim/xrtsim_vcs/simv'
            identity = {p.name: digest(p) for p in simv.parent.glob('simv.daidir/*.so')}
            identity['simv'] = digest(simv) if simv.exists() else None
            if sim_identity is None:
                sim_identity = identity
                save(out / 'simulator_identity.json', identity)
            kernel = build / 'tests/regression/fpint_gemm_ffn_hw/kernel.vxbin'
            result = {'banks': banks, 'M': m, 'repeat': repeat, 'returncode': rc,
                      'passed': passed, 'metrics': metrics, 'errors': errors,
                      'kernel_sha256': digest(kernel) if kernel.exists() else None,
                      'simulator_unchanged': identity == sim_identity}
            save(case / 'result.json', result)
            results.append(result)
            save(out / 'results.json', results)
            print('RESULT ' + json.dumps(result), flush=True)
            if rc or not passed or errors or not metrics or metrics['total_cycles'] <= 0 or identity != sim_identity:
                raise RuntimeError(f'Invalid measurement: {case}')
    changed = [p for p, h in sources.items() if digest(ROOT / p) != h]
    save(out / 'source_integrity.json', {'changed': changed})
    if changed:
        raise RuntimeError('RTL changed during measurement')
    return results

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--k', type=int, default=256)
    parser.add_argument('--n', type=int, default=256)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--resume', action='store_true', help='Reuse successful, archived executions with identical configuration.')
    args = parser.parse_args()
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(profile, b, args) for b in [16, 8]]
        runs = [row for f in futures for row in f.result()]
    table = []
    for m in [1, 4, 256]:
        values = {b: [r['metrics']['total_cycles'] for r in runs if r['banks'] == b and r['M'] == m] for b in [16, 8]}
        med = {b: statistics.median(v) for b, v in values.items()}
        table.append({'M': m, 'cycles16': values[16], 'cycles8': values[8],
                      'median16': med[16], 'median8': med[8],
                      'increase8_pct': (med[8] / med[16] - 1) * 100})
    save(TASK / 'comparison.json', table)
    print('COMPARISON ' + json.dumps(table), flush=True)

if __name__ == '__main__':
    main()
