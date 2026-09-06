#!/usr/bin/env python3
"""Fresh-build MXU16/MXU32 GEMM-cycle comparison, HBM4/DMA4/TMEM8/512KiB."""
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
ERROR_RE = re.compile(
    r'^\s*(?:error|fatal)(?::|-\[|\s*\[)|^\s*FAILED\b|\b(?:TEST|OUTPUT CHECK) FAILED\b|Mismatch\[',
    re.IGNORECASE)
PERF_RE = re.compile(r'^PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def snapshot():
    paths = set((ROOT / 'hw/rtl').rglob('*'))
    for folder in ['kernel/include', 'kernel/src', 'runtime/include', 'runtime/stub',
                   'runtime/xrt', 'sim/xrtsim_vcs', 'tests/regression/fpint_gemm_ffn_hw']:
        paths.update((ROOT / folder).rglob('*'))
    return {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)
            if p.is_file() and p.suffix in ('.sv', '.v', '.vh', '.cpp', '.c', '.h', '.hpp', '.S')}


def simulator_identity(build):
    base = build / 'sim/xrtsim_vcs'
    paths = [base / 'simv', *sorted(base.glob('simv.daidir/*.so'))]
    if not all(p.exists() for p in paths):
        raise RuntimeError('Missing simulator binary')
    return {str(p.relative_to(base)): digest(p) for p in paths}


def parse_case(case):
    errors, metrics = [], []
    passed = 0
    for name in ['wrapper.log', 'simv.log']:
        path = case / name
        if not path.exists():
            errors.append(f'Missing {name}')
            continue
        with path.open(errors='replace') as stream:
            for line in stream:
                if ERROR_RE.search(line) and len(errors) < 30:
                    errors.append(f'{name}: {line.strip()}')
                if name == 'wrapper.log':
                    passed += line.strip() == 'PASSED'
                    match = PERF_RE.match(line)
                    if match:
                        metrics.append(dict(zip(['jobs', 'total_cycles', 'busy_cycles'],
                                                map(int, match.groups()))))
    return passed == 1, metrics[0] if len(metrics) == 1 else None, errors


def profile(mxu, args):
    config = ROOT / f'configs/improve_th16_tcol{mxu}_m{mxu}_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh'
    build = ROOT / f'build_mxu_compare_hbm4_m{mxu}_{args.run_id}'
    out = TASK / args.run_id / f'mxu{mxu}'
    build.mkdir(exist_ok=False)
    out.mkdir(parents=True, exist_ok=False)
    with (out / 'configure.log').open('w') as log:
        subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                        '--prefix=' + os.environ['HOME'] + '/tools/vortex'],
                       cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True)
    raw = subprocess.check_output(['bash', '-c', 'source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
    env = dict(s.split('=', 1) for s in raw.decode().split('\0') if '=' in s)
    env.update(PATH='/usr/bin:' + env['PATH'], CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0')
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'VCS_SIMV_FLAGS',
                'XRT_XCLBIN_PATH', 'FPGA_BIN_DIR']:
        env.pop(key, None)
    defines = dict((d[2:].split('=', 1) if '=' in d else [d[2:], None])
                   for d in env['CONFIGS'].split())
    for key, value in {'NUM_TMEM_BANKS': 8, 'NUM_DMA_CHANNELS': 4, 'NUM_HBM_PORTS': 4,
                       'TMEM_BANK_SIZE': 65536, 'NUM_THREADS': 16, 'GEMM_TIMING_CUTS': 1,
                       'MXU_ROW': mxu, 'MXU_COL': mxu, 'MXU_COL_TILE': mxu}.items():
        assert defines[key] == str(value), (key, defines[key], value)
    sources = snapshot()
    config_hash = digest(config)
    save(out / 'manifest.json', {
        'started': datetime.now().isoformat(), 'config': str(config), 'config_sha256': config_hash,
        'CONFIGS': env['CONFIGS'], 'build': str(build), 'mxu': mxu,
        'banks': 8, 'dma_channels': 4, 'hbm_ports': 4, 'bank_bytes': 65536,
        'bank_word_bytes': mxu * 2, 'bank_depth': 65536 // (mxu * 2), 'total_tmem_bytes': 524288,
        'K': 256, 'N': 256, 'qblk': 32, 'qdir': 0, 'transposed': 0, 'repeats': args.repeats,
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'source_sha256': sources,
        'memory_environment': {k: v for k, v in env.items() if k.startswith(('DRAM_', 'CACHE_'))}})
    rows = []
    identity = None
    kernel_hash = None
    for m in [1, 4, 256]:
        for repeat in range(args.repeats):
            if snapshot() != sources or digest(config) != config_hash:
                raise RuntimeError('Sources/config changed during measurement')
            case = out / f'm{m}_r{repeat}'
            case.mkdir()
            command = ['timeout', '300' if m != 256 else '1800', './ci/run_black.sh',
                       'xrt-vcs-sim', '--perf', '3', '--app', 'fpint_gemm_ffn_hw',
                       '--args', f'-m {m} -k 256 -n 256 -q 32 -d 0 -t 0 -r 1']
            save(case / 'command.json', {'argv': command, 'cwd': str(build), 'CONFIGS': env['CONFIGS']})
            print(f'START mxu={mxu} M={m} repeat={repeat}', flush=True)
            with (case / 'wrapper.log').open('w') as log:
                rc = subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
            simlog = build / 'sim/xrtsim_vcs/simv.log'
            if simlog.exists():
                shutil.copy2(simlog, case / 'simv.log')
            compilelog = build / 'sim/xrtsim_vcs/compile.log'
            if compilelog.exists() and not (out / 'compile.log').exists():
                shutil.copy2(compilelog, out / 'compile.log')
            passed, metrics, errors = parse_case(case)
            current_identity = simulator_identity(build) if (build / 'sim/xrtsim_vcs/simv').exists() else None
            if identity is None:
                identity = current_identity
                save(out / 'simulator_identity.json', identity)
            kernel = build / 'tests/regression/fpint_gemm_ffn_hw/kernel.vxbin'
            current_kernel = digest(kernel) if kernel.exists() else None
            if kernel_hash is None:
                kernel_hash = current_kernel
            result = {'mxu': mxu, 'M': m, 'repeat': repeat, 'returncode': rc,
                      'passed': passed, 'metrics': metrics, 'errors': errors,
                      'kernel_sha256': current_kernel,
                      'simulator_unchanged': current_identity == identity,
                      'kernel_unchanged': current_kernel == kernel_hash}
            save(case / 'result.json', result)
            rows.append(result)
            save(out / 'results.json', rows)
            print('RESULT ' + json.dumps(result), flush=True)
            if (rc or not passed or errors or not metrics or metrics['total_cycles'] <= 0
                    or current_identity is None or current_identity != identity
                    or current_kernel is None or current_kernel != kernel_hash):
                raise RuntimeError(f'Invalid measurement: {case}')
    unchanged = snapshot() == sources and digest(config) == config_hash
    save(out / 'source_integrity.json', {'unchanged': unchanged})
    if not unchanged:
        raise RuntimeError('Sources/config changed during measurement')
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-id', default=datetime.now().strftime('%Y%m%d_%H%M%S'))
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_]+', args.run_id) or args.repeats < 1:
        parser.error('run-id must be alphanumeric/underscore; repeats must be positive')
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(profile, mxu, args) for mxu in [16, 32]]
        rows = [r for f in futures for r in f.result()]
    table = []
    for m in [1, 4, 256]:
        values = {x: [r['metrics']['total_cycles'] for r in rows if r['mxu'] == x and r['M'] == m]
                  for x in [16, 32]}
        med = {x: statistics.median(v) for x, v in values.items()}
        table.append({'M': m, 'cycles_m16': values[16], 'cycles_m32': values[32],
                      'median_m16': med[16], 'median_m32': med[32],
                      'm32_cycle_reduction_pct': (1 - med[32] / med[16]) * 100,
                      'm32_cycle_speedup': med[16] / med[32]})
    save(TASK / args.run_id / 'comparison.json', table)
    print('COMPARISON ' + json.dumps(table), flush=True)


if __name__ == '__main__':
    main()
