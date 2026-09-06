#!/usr/bin/env python3
"""Archive and replay the exact performance simulators, preserving each FSDB."""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
TASK = Path(__file__).resolve().parent
PERF = TASK.parent
helper = ROOT / 'agent-tasks/mxu16-vs-mxu32-hbm4-tmem8/run_comparison.py'
spec = importlib.util.spec_from_file_location('common', helper)
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)

def capture(c):
    old = PERF / f'ch{c}'
    manifest = json.loads((old / 'manifest.json').read_text())
    build = Path(manifest['build'])
    config = Path(manifest['config'])
    identity = json.loads((old / 'simulator_identity.json').read_text())
    assert common.snapshot() == manifest['source_sha256'], 'RTL/software changed since measurement'
    assert common.digest(config) == manifest['config_sha256'], 'Config changed'
    assert common.simulator_identity(build) == identity, 'Simulator changed'
    out = TASK / f'ch{c}'
    out.mkdir(exist_ok=False)
    archived = out / 'previous_m256'
    archived.mkdir()
    for name in ['vcs_cosim.fsdb', 'simv.log', 'compile.log']:
        shutil.copy2(build / 'sim/xrtsim_vcs' / name, archived / name)
    raw = subprocess.check_output(['bash', '-c', 'source "$1"; env -0', 'bash', str(config)], cwd=ROOT)
    env = dict(s.split('=', 1) for s in raw.decode().split('\0') if '=' in s)
    assert env['CONFIGS'] == manifest['CONFIGS']
    env.update(PATH='/usr/bin:' + env['PATH'], CC='/usr/bin/gcc', CXX='/usr/bin/g++', GUI='0')
    for key in ['DEBUG', 'PERF', 'SCOPE', 'LOG_MAX_BYTES', 'VCS_SIMV_FLAGS', 'XRT_XCLBIN_PATH', 'FPGA_BIN_DIR', 'NDEBUG']:
        env.pop(key, None)
    results = []
    for m in [1, 4]:
        case = out / f'm{m}'
        case.mkdir()
        command = ['timeout', '300', './ci/run_black.sh', 'xrt-vcs-sim', '--perf', '3',
                   '--app', 'fpint_gemm_ffn_hw', '--args', f'-m {m} -k 256 -n 256 -q 32 -d 0 -t 0 -r 1']
        common.save(case / 'command.json', {'argv': command, 'CONFIGS': env['CONFIGS'], 'cwd': str(build)})
        print(f'START ch{c} M{m}', flush=True)
        with (case / 'wrapper.log').open('w') as log:
            rc = subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        for name in ['vcs_cosim.fsdb', 'simv.log']:
            shutil.copy2(build / 'sim/xrtsim_vcs' / name, case / name)
        passed, metrics, errors = common.parse_case(case)
        unchanged = common.simulator_identity(build) == identity and common.snapshot() == manifest['source_sha256']
        result = {'channels': c, 'M': m, 'rc': rc, 'passed': passed, 'metrics': metrics,
                  'errors': errors, 'unchanged': unchanged, 'fsdb_sha256': common.digest(case / 'vcs_cosim.fsdb')}
        common.save(case / 'result.json', result)
        results.append(result)
        print(json.dumps(result), flush=True)
        assert rc == 0 and passed and metrics and not errors and unchanged
    return results

if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = [row for result in pool.map(capture, [8, 4]) for row in result]
    common.save(TASK / 'capture_results.json', rows)
