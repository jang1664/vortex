#!/usr/bin/env python3
"""Isolated validation of conditional naive internal-ACC plumbing."""
import copy
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE = ROOT / 'agent-tasks/paper-vs-current-rtl'
spec = importlib.util.spec_from_file_location('comparison', BASE / 'run_compare.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.HERE = HERE
PATCHED = ['hw/rtl/VX_config.vh', 'hw/rtl/VX_gpu_pkg.sv', 'hw/rtl/core/VX_mem_unit.sv',
           'hw/rtl/core/gemm/VX_gemm_node_naive.sv', 'hw/rtl/mem/VX_local_mem.sv']


def prepare():
    old = json.loads((ROOT / 'agent-tasks/omega-ordering-macros/blackbox/summary.json').read_text())['variants'][0]
    sources = {}
    for software in ('historical', 'current'):
        source = ROOT / ('build_paper_vs_current_sources/C3_acc_cleanup_' + software)
        assert not source.exists(), 'Inspect partial preparation: ' + str(source)
        source.mkdir()
        m.extract(m.CURRENT, source, m.PATHS)
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0',
                        '--no-backup-if-mismatch', '-p1'],
                       input=(HERE / 'rtl.patch').read_bytes(), cwd=source, check=True)
        if software == 'historical':
            (source / ('tests/regression/' + old['app'])).rename(source / ('tests/regression/' + old['app'] + '_unused'))
            m.extract(old['app_commit'], source, ['tests/regression/' + old['app']])
        (source / 'third_party').symlink_to(ROOT / 'third_party', target_is_directory=True)
        sources[software] = source
    modes = [('acc_omega', 'historical'), ('acc_stream', 'historical'),
             ('acc_slr', 'historical'), ('acc_guarded', 'historical'), ('external', 'current')]
    templates = {}
    for mode, software in modes:
        source = sources[software]
        flags = shlex.split(old['configs'])
        if mode == 'acc_stream':
            flags = [f for f in flags if f not in ('-DLMEM_REQ_OMEGA_ENABLE', '-DLMEM_RSP_OMEGA_ENABLE')]
        if mode == 'acc_slr':
            flags.append('-DGEMM_SLR_PIPELINE')
        if mode in ('external', 'acc_guarded'):
            flags = [f for f in flags if f not in ('-DLMEM_REQ_OMEGA_ORDER_DISABLE', '-DLMEM_RSP_OMEGA_ORDER_DISABLE')]
        if mode == 'external':
            flags.remove('-DGEMM_NAIVE_USE_ACC_MEM')
        config = source / ('configs/acc_cleanup_' + mode + '.sh')
        config.write_text('export CONFIGS=' + shlex.quote(' '.join(flags)) + '\n')
        build = source / ('build_' + mode)
        build.mkdir()
        logs = HERE / 'logs' / (mode + '_setup')
        logs.mkdir(parents=True)
        env = m.environment(config)
        rc, _ = m.execute(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                          '--prefix=' + str(Path.home() / 'tools/vortex')], build, env, logs / 'configure.log')
        assert rc == 0
        for directory in ('hw', 'runtime/stub', 'kernel'):
            rc, _ = m.execute(['make', '-C', directory], build, env,
                             logs / (directory.replace('/', '_') + '.log'))
            assert rc == 0
        v = dict(case='external' if mode == 'external' else 'C3', label=mode, source=str(source),
                 build=str(build), app=old['app'], config=str(config), configs=' '.join(flags),
                 config_sha256=m.digest(config), rtl_commit=m.CURRENT,
                 app_commit=old['app_commit'] if software == 'historical' else m.CURRENT,
                 rtl_patch_sha256={f: m.digest(source / f) for f in PATCHED})
        v['source_sha256'] = {str(p.relative_to(source)): m.digest(p)
            for directory in ('hw/rtl', 'sim/xrtsim_vcs', 'runtime', 'kernel', 'tests/regression/' + old['app'])
            for p in sorted((source / directory).rglob('*')) if p.is_file()}
        templates[mode] = v
        print('PREPARED', mode, flush=True)
    variants = []
    for mode, rows in [('acc_omega', 1), ('acc_omega', 4), ('acc_omega', 256),
                       ('acc_stream', 4), ('acc_slr', 4), ('acc_guarded', 4), ('external', 4)]:
        v = copy.deepcopy(templates[mode])
        v.update(name=f'{mode}_M{rows}', M=rows, measurements=[],
                 args=f'-m {rows} -k 256 -n 256 -q 32 -t 0 -d 0 -r 1')
        (HERE / 'logs' / v['name']).mkdir(parents=True)
        variants.append(v)
    (HERE / 'artifacts').mkdir()
    (HERE / 'artifacts/C3').symlink_to(BASE / 'artifacts/C3', target_is_directory=True)
    state = dict(variants=variants, baseline='Prior unguarded Omega C3 measurements, identical historical host/kernel binaries', repetitions=1)
    m.save(HERE / 'summary.json', state)
    return state


if __name__ == '__main__':
    state = json.loads((HERE / 'summary.json').read_text()) if (HERE / 'summary.json').exists() else prepare()
    for v in state['variants']:
        if not any(e['passed'] for e in v['measurements']):
            m.measure(state, v, 1)
    print('PASS: all seven validation runs', flush=True)
