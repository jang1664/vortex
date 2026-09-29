#!/usr/bin/env python3
"""Validate unguarded Omega with matched C3 M256 internal-ACC software."""
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = ROOT / 'agent-tasks/paper-vs-current-rtl'
spec = importlib.util.spec_from_file_location('comparison', BASE / 'run_compare.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.HERE = HERE / 'blackbox'
m.HERE.mkdir(exist_ok=True)


def main():
    state_file = m.HERE / 'summary.json'
    if state_file.exists():
        state = json.loads(state_file.read_text())
    else:
        baseline = next(v for v in json.loads((BASE / 'summary.json').read_text())['variants'] if v['name'] == 'C3_off')
        source = ROOT / 'build_paper_vs_current_sources/C3_omega_order_bypass'
        assert not source.exists(), 'Preparation already exists; inspect before retrying'
        source.mkdir()
        m.extract(m.CURRENT, source, m.PATHS)
        changed = ('hw/rtl/VX_config.vh', 'hw/rtl/mem/VX_local_mem.sv')
        patch = (HERE / 'rtl.patch').read_bytes()
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0',
                        '--no-backup-if-mismatch', '-p1'], input=patch, cwd=source, check=True)
        app = baseline['app']
        (source / ('tests/regression/' + app)).rename(source / ('tests/regression/' + app + '_unused'))
        m.extract(baseline['app_commit'], source, ['tests/regression/' + app])
        (source / 'third_party').symlink_to(ROOT / 'third_party', target_is_directory=True)
        tokens = shlex.split(baseline['configs']) + ['-DLMEM_REQ_OMEGA_ORDER_DISABLE', '-DLMEM_RSP_OMEGA_ORDER_DISABLE']
        config = source / 'configs/paper_omega_order_bypass.sh'
        config.write_text('export CONFIGS=' + shlex.quote(' '.join(tokens)) + '\n')
        build = source / 'build'
        build.mkdir()
        logs = m.HERE / 'logs/C3_bypass'
        logs.mkdir(parents=True)
        env = m.environment(config)
        rc, _ = m.execute(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                          '--prefix=' + str(Path.home() / 'tools/vortex')], build, env, logs / 'configure.log')
        assert rc == 0
        for directory in ('hw', 'runtime/stub', 'kernel'):
            rc, _ = m.execute(['make', '-C', directory], build, env, logs / (directory.replace('/', '_') + '.log'))
            assert rc == 0
        v = dict(name='C3_bypass', case='C3', label='current_off_unguarded_omega', source=str(source),
                 build=str(build), app=app, config=str(config), configs=' '.join(tokens),
                 config_sha256=m.digest(config), rtl_commit=m.CURRENT, app_commit=baseline['app_commit'],
                 rtl_patch_sha256={f: m.digest(source / f) for f in changed}, measurements=[])
        v['source_sha256'] = {str(p.relative_to(source)): m.digest(p)
            for directory in ('hw/rtl', 'sim/xrtsim_vcs', 'runtime', 'kernel', 'tests/regression/' + app)
            for p in sorted((source / directory).rglob('*')) if p.is_file()}
        state = dict(variants=[v], purpose='Verify new compile-time bypass with both Omega fabrics, internal ACC and SLR OFF')
        m.save(state_file, state)
        (m.HERE / 'artifacts').symlink_to(BASE / 'artifacts', target_is_directory=True)
    if '--prepare-only' in sys.argv:
        print('PREPARED isolated blackbox', flush=True)
        return
    unit_results = json.loads((HERE / 'unit_results.json').read_text())
    assert len(unit_results) == 9 and all(r['passed'] for r in unit_results)
    v = state['variants'][0]
    if not any(e['passed'] for e in v['measurements']):
        m.measure(state, v, 1)
    print('PASS: M256 unguarded Omega', flush=True)


if __name__ == '__main__':
    main()
