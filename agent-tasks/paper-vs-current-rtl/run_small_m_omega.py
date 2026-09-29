#!/usr/bin/env python3
"""Matched M1/M4 C3/C4 measurements with unguarded request/response Omega."""
import copy
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[1]
OUT = BASE / 'small_m_omega'
OUT.mkdir(exist_ok=True)
spec = importlib.util.spec_from_file_location('comparison', BASE / 'run_compare.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.HERE = OUT
CHANGED = ['hw/rtl/VX_config.vh', 'hw/rtl/mem/VX_local_mem.sv']


def prepare():
    primary = json.loads((BASE / 'summary.json').read_text())
    vv = {v['name']: v for v in primary['variants']}
    c3_current = json.loads((ROOT / 'agent-tasks/omega-ordering-macros/blackbox/summary.json').read_text())['variants'][0]
    assert all(m.digest(Path(c3_current['source']) / f) == d
               for f, d in c3_current['rtl_patch_sha256'].items())
    templates = [copy.deepcopy(vv['C3_old']), copy.deepcopy(c3_current)]
    templates[0]['label'] = 'old'
    templates[1]['label'] = 'current'
    # C4's historical commit already includes ordering. Backport only the
    # selector patch to the archived copy so both revisions truly bypass it.
    patch = (ROOT / 'agent-tasks/omega-ordering-macros/rtl.patch').read_bytes()
    assert patch
    (OUT / 'ordering_controls.patch').write_bytes(patch)
    for label in ('old', 'current'):
        original = vv['C4_old' if label == 'old' else 'C4_off']
        source = ROOT / ('build_paper_vs_current_sources/C4_small_omega_' + label)
        assert not source.exists(), 'Inspect partial preparation before retry: ' + str(source)
        source.mkdir()
        m.extract(m.CURRENT, source, m.PATHS)
        if label == 'old':
            (source / 'hw/rtl').rename(source / 'hw/rtl_current_unused')
            m.extract(original['rtl_commit'], source, ['hw/rtl'])
            command = ['patch', '--batch', '--forward', '--fuzz=0', '--no-backup-if-mismatch', '-p1']
            check = subprocess.run(command + ['--dry-run'], input=patch, cwd=source, capture_output=True)
            assert check.returncode == 0, check.stdout.decode() + check.stderr.decode()
            applied = subprocess.run(command, input=patch, cwd=source, capture_output=True)
            assert applied.returncode == 0
            (OUT / 'historical_patch_application.log').write_bytes(applied.stdout + applied.stderr)
        else:
            subprocess.run(['patch', '--batch', '--forward', '--fuzz=0',
                            '--no-backup-if-mismatch', '-p1'], input=patch, cwd=source, check=True)
        app = original['app']
        (source / ('tests/regression/' + app)).rename(source / ('tests/regression/' + app + '_unused'))
        m.extract(original['app_commit'], source, ['tests/regression/' + app])
        (source / 'third_party').symlink_to(ROOT / 'third_party', target_is_directory=True)
        flags = list(dict.fromkeys(shlex.split(original['configs']) + [
            '-DLMEM_REQ_OMEGA_ENABLE', '-DLMEM_RSP_OMEGA_ENABLE',
            '-DLMEM_REQ_OMEGA_ORDER_DISABLE', '-DLMEM_RSP_OMEGA_ORDER_DISABLE']))
        config = source / 'configs/paper_small_m_omega.sh'
        config.write_text('export CONFIGS=' + shlex.quote(' '.join(flags)) + '\n')
        build = source / 'build'
        build.mkdir()
        logs = OUT / 'logs' / ('C4_' + label + '_setup')
        logs.mkdir(parents=True)
        env = m.environment(config)
        rc, _ = m.execute(['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                          '--prefix=' + str(Path.home() / 'tools/vortex')], build, env, logs / 'configure.log')
        assert rc == 0
        for directory in ('hw', 'runtime/stub', 'kernel'):
            rc, _ = m.execute(['make', '-C', directory], build, env,
                              logs / (directory.replace('/', '_') + '.log'))
            assert rc == 0
        v = dict(case='C4', label=label, source=str(source), build=str(build), app=app,
                 config=str(config), configs=' '.join(flags), config_sha256=m.digest(config),
                 rtl_commit=original['rtl_commit'], app_commit=original['app_commit'],
                 rtl_patch_sha256={f: m.digest(source / f) for f in CHANGED})
        v['source_sha256'] = {str(p.relative_to(source)): m.digest(p)
            for directory in ('hw/rtl', 'sim/xrtsim_vcs', 'runtime', 'kernel', 'tests/regression/' + app)
            for p in sorted((source / directory).rglob('*')) if p.is_file()}
        templates.append(v)
        print('PREPARED C4', label, flush=True)
    audit = []
    for v in templates:
        source = Path(v['source'])
        dirs = sorted({p.parent for p in (source / 'hw/rtl').rglob('*.vh')})
        command = ['verilator', '-E', '-P', '-sv', *shlex.split(v['configs']),
                   *['-I' + str(p) for p in dirs], str(source / 'hw/rtl/mem/VX_local_mem.sv')]
        pre = subprocess.run(command, capture_output=True, text=True)
        assert pre.returncode == 0, pre.stderr
        assert pre.stdout.count('VX_stream_omega #(') == 2
        assert 'store_cam_valid' not in pre.stdout and 'rsp_order_issued' not in pre.stdout
        assert '-DGEMM_SLR_PIPELINE' not in v['configs']
        audit.append(dict(case=v['case'], label=v['label'], omega_instances=2,
                          store_guard=False, response_guard=False, slr=False))
    m.save(OUT / 'config_audit.json', audit)
    variants = []
    for rows in (1, 4):
        for template in templates:
            v = copy.deepcopy(template)
            for k in ('statistics', 'command', 'artifact_sha256', 'long_run_required'):
                v.pop(k, None)
            v.update(name=f'{v["case"]}_{v["label"]}_M{rows}', M=rows, measurements=[],
                     args=f'-m {rows} -k 256 -n 256 -q 32 -t 0 -d 0 -r 1')
            (OUT / 'logs' / v['name']).mkdir(parents=True)
            variants.append(v)
    state = dict(current=m.CURRENT, variants=variants, repetitions=1,
                 note='C4 old receives ordering-control-only patch; all configurations use unguarded request/response Omega.')
    (OUT / 'artifacts').symlink_to(BASE / 'artifacts', target_is_directory=True)
    m.save(OUT / 'summary.json', state)
    return state


def report(state):
    lines = ['# M1/M4 old/current comparison: unguarded Omega', '',
             'K=N=256, q32, t0, d0, r1; xrt-vcs-sim --perf 3; SLR OFF. One run per configuration.',
             'C3 uses internal ACC. Request and response Omega are enabled; both ordering guards are absent.',
             'C3 historical commit: 93f4ae97d. C4 historical commit: 391b45d39 plus ordering-selector-only backport.',
             'Current base: 18ab7f92 plus the same new ordering controls.', '',
             '| Backend | M | Old node cycles | Current node cycles | Change | Correctness |',
             '| --- | ---: | ---: | ---: | ---: | --- |']
    for case in ('C3', 'C4'):
        for rows in (1, 4):
            variants = [v for v in state['variants'] if v['case'] == case and v['M'] == rows]
            es = [next((e for e in v['measurements'] if e['passed']), None) for v in variants]
            av, bv = [e['total_cycles'] if e else None for e in es]
            change = f'{100*(bv/av-1):+.3f}%' if av and bv else 'unavailable'
            passed = 'both PASS' if all(es) else 'incomplete/failed; see summary.json'
            lines.append(f'| {case} | {rows} | {av or "—"} | {bv or "—"} | {change} | {passed} |')
    lines += ['', 'Each backend reuses its identical host/kernel binaries from the M256 comparison.',
              'These are single-sample RTL cycle measurements, not FPGA Fmax/wall-clock measurements.',
              'C4 originally used stream xbar in the paper configuration; this experiment explicitly selects Omega on both revisions.',
              'No additional product RTL edits. Raw counters, command lines, source/config/artifact hashes: summary.json and logs/.', '']
    (OUT / 'results.md').write_text('\n'.join(lines))


if __name__ == '__main__':
    state = json.loads((OUT / 'summary.json').read_text()) if (OUT / 'summary.json').exists() else prepare()
    for v in state['variants']:
        if any(e['passed'] for e in v['measurements']):
            continue
        try:
            m.measure(state, v, 1)
        except AssertionError as error:
            # Historical failures are evidence, not permission to alter baseline RTL.
            print('FAILED', v['name'], str(error), flush=True)
            v['error'] = str(error)
            m.save(OUT / 'summary.json', state)
        report(state)
    print('DONE', sum(any(e['passed'] for e in v['measurements']) for v in state['variants']), '/ 8 passed', flush=True)
