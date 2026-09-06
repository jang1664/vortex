#!/usr/bin/env python3
"""Compare MXU32 direct8/direct4 profiles with equal512KiB TMEM capacity."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
# Reuse the previous comparison's tested strict log parser and hash helpers.
HELPER = ROOT / 'agent-tasks/mxu16-vs-mxu32-hbm4-tmem8/run_comparison.py'
spec = importlib.util.spec_from_file_location('mxu_perf_helpers', HELPER)
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)


def prepare(channels):
    capacity = 524288 // channels
    config = ROOT / f'configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm{channels}_tmem{channels}.sh'
    build = ROOT / f'build_mxu32_channels{channels}_perf_iter1'
    out = TASK / f'ch{channels}'
    build.mkdir(exist_ok=False)
    out.mkdir(exist_ok=False)
    raw = subprocess.check_output(['bash', '-c', 'source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
    env = dict(s.split('=', 1) for s in raw.decode().split('\0') if '=' in s)
    env.update(PATH='/usr/bin:' + env['PATH'], CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0')
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'VCS_SIMV_FLAGS', 'XRT_XCLBIN_PATH', 'FPGA_BIN_DIR', 'NDEBUG']:
        env.pop(key, None)
    tokens = env['CONFIGS'].split()
    definitions = dict(t[2:].split('=', 1) if '=' in t else [t[2:], None] for t in tokens)
    assert len(definitions) == len(tokens), 'Duplicate defines'
    for key, value in {'NUM_HBM_PORTS': channels, 'NUM_DMA_CHANNELS': channels,
                       'NUM_TMEM_BANKS': channels, 'TMEM_BANK_SIZE': capacity,
                       'MXU_ROW': 32, 'MXU_COL': 32, 'MXU_COL_TILE': 32,
                       'NUM_THREADS': 16, 'GEMM_TIMING_CUTS': 1}.items():
        assert definitions[key] == str(value), (key, definitions[key], value)
    sources = common.snapshot()
    config_hash = common.digest(config)
    common.save(out / 'manifest.json', {
        'started': datetime.now().isoformat(), 'config': str(config), 'config_sha256': config_hash,
        'CONFIGS': env['CONFIGS'], 'build': str(build), 'channels': channels,
        'hbm_ports': channels, 'tmem_banks': channels, 'bank_bytes': capacity,
        'bank_word_bytes': 64, 'bank_depth': capacity // 64, 'total_tmem_bytes': 524288,
        'K': 256, 'N': 256, 'qblk': 32, 'qdir': 0, 'transposed': 0, 'repeats': 3,
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'source_sha256': sources, 'helper_sha256': common.digest(HELPER),
        'memory_environment': {k: v for k, v in env.items() if k.startswith(('DRAM_', 'CACHE_'))}})
    with (out / 'configure.log').open('w') as log:
        subprocess.run(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                        '--prefix=' + env['HOME'] + '/tools/vortex'], cwd=build, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    # Exercise the real bank/direct path, including upper/lower-row retention
    # for the 2048-deep organization, before any performance launch.
    unit_env = dict(env, TMEM_BYTES='64', TMEM_BANKS=str(channels),
                    TMEM_BANK_SIZE=str(capacity), NDEBUG='1')
    unit = build / 'hw/unittest/tmem_dma_write_ack_filter'
    command = ['python3', str(ROOT / 'tools/verify_rtl.py'), 'unittest', '--path', str(unit),
               '--sim', 'vcs', '--timeout', '60']
    print(f'UNIT START channels={channels}', flush=True)
    result = subprocess.run(command, cwd=build, env=unit_env, capture_output=True, text=True)
    (out / 'unit_verify.json').write_text(result.stdout)
    (out / 'unit_verify.stderr').write_text(result.stderr)
    errors = []
    unit_out = out / 'unit_logs'
    unit_out.mkdir()
    for path in (unit / 'logs').glob('*.log'):
        shutil.copy2(path, unit_out / path.name)
        with path.open(errors='replace') as log:
            errors.extend(line.strip() for line in log if common.ERROR_RE.search(line))
    verified = json.loads(result.stdout)
    verdict = {'returncode': result.returncode, 'verify': verified, 'errors': errors,
               'passed': result.returncode == 0 and verified['status'] == 'pass' and not errors}
    common.save(out / 'unit_result.json', verdict)
    print(f'UNIT RESULT channels={channels} ' + json.dumps(verdict), flush=True)
    if not verdict['passed']:
        raise RuntimeError(f'Unit failed: channels={channels}')
    return channels, config, config_hash, build, out, env, sources


def measure(prepared):
    channels, config, config_hash, build, out, env, sources = prepared
    identity, kernel_hash = None, None
    rows = []
    for m in [1, 4, 256]:
        for repeat in range(3):
            assert common.snapshot() == sources and common.digest(config) == config_hash, 'Sources changed'
            case = out / f'm{m}_r{repeat}'
            case.mkdir()
            command = ['timeout', '300' if m != 256 else '1800', './ci/run_black.sh',
                       'xrt-vcs-sim', '--perf', '3', '--app', 'fpint_gemm_ffn_hw',
                       '--args', f'-m {m} -k 256 -n 256 -q 32 -d 0 -t 0 -r 1']
            common.save(case / 'command.json', {'argv': command, 'cwd': str(build), 'CONFIGS': env['CONFIGS']})
            print(f'START channels={channels} M={m} repeat={repeat}', flush=True)
            with (case / 'wrapper.log').open('w') as log:
                rc = subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
            simlog = build / 'sim/xrtsim_vcs/simv.log'
            if simlog.exists():
                shutil.copy2(simlog, case / 'simv.log')
            compilelog = build / 'sim/xrtsim_vcs/compile.log'
            if compilelog.exists() and not (out / 'compile.log').exists():
                shutil.copy2(compilelog, out / 'compile.log')
            passed, metrics, errors = common.parse_case(case)
            current_identity = common.simulator_identity(build) if (build / 'sim/xrtsim_vcs/simv').exists() else None
            kernel = build / 'tests/regression/fpint_gemm_ffn_hw/kernel.vxbin'
            current_kernel = common.digest(kernel) if kernel.exists() else None
            if identity is None:
                identity = current_identity
                common.save(out / 'simulator_identity.json', identity)
            if kernel_hash is None:
                kernel_hash = current_kernel
            result = {'channels': channels, 'M': m, 'repeat': repeat, 'returncode': rc,
                      'passed': passed, 'metrics': metrics, 'errors': errors,
                      'kernel_sha256': current_kernel, 'simulator_unchanged': current_identity == identity,
                      'kernel_unchanged': current_kernel == kernel_hash}
            common.save(case / 'result.json', result)
            rows.append(result)
            common.save(out / 'results.json', rows)
            print('RESULT ' + json.dumps(result), flush=True)
            if (rc or not passed or errors or not metrics or metrics['total_cycles'] <= 0
                    or current_identity is None or current_identity != identity
                    or current_kernel is None or current_kernel != kernel_hash):
                raise RuntimeError(f'Invalid measurement: {case}')
    unchanged = common.snapshot() == sources and common.digest(config) == config_hash
    common.save(out / 'source_integrity.json', {'unchanged': unchanged})
    assert unchanged, 'Sources changed during measurement'
    return rows


def main():
    with ThreadPoolExecutor(max_workers=2) as pool:
        prepared = list(pool.map(prepare, [8, 4]))
    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = [r for result in pool.map(measure, prepared) for r in result]
    table = []
    for m in [1, 4, 256]:
        values = {c: [r['metrics']['total_cycles'] for r in rows if r['channels'] == c and r['M'] == m]
                  for c in [8, 4]}
        med = {c: statistics.median(v) for c, v in values.items()}
        table.append({'M': m, 'cycles8': values[8], 'cycles4': values[4], 'median8': med[8],
                      'median4': med[4], 'increase4_pct': (med[4] / med[8] - 1) * 100})
    common.save(TASK / 'comparison.json', table)
    print('COMPARISON ' + json.dumps(table), flush=True)


if __name__ == '__main__':
    main()
