#!/usr/bin/env python3
"""One matched C3 run per revision/SLR variant using stream xbar."""
import importlib.util
import json
from pathlib import Path
import shlex

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('comparison', HERE / 'run_compare.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)
OUT = HERE / 'stream_xbar'
OUT.mkdir(exist_ok=True)
comparison.HERE = OUT


def main():
    state_file = OUT / 'summary.json'
    if state_file.exists():
        state = json.loads(state_file.read_text())
    else:
        original = json.loads((HERE / 'summary.json').read_text())
        variants = []
        for old in original['variants']:
            if old['case'] != 'C3':
                continue
            v = {k: old[k] for k in ('name', 'case', 'label', 'source', 'app',
                                    'rtl_commit', 'app_commit', 'source_sha256')}
            source = Path(v['source'])
            tokens = shlex.split(old['configs'])
            remove = {'-DLMEM_REQ_OMEGA_ENABLE', '-DLMEM_RSP_OMEGA_ENABLE'}
            assert remove.issubset(tokens)
            tokens = [t for t in tokens if t not in remove]
            config = source / 'configs/paper_stream_xbar.sh'
            config.write_text('export CONFIGS=' + shlex.quote(' '.join(tokens)) + '\n')
            build = source / 'build_stream_xbar'
            build.mkdir(exist_ok=True)
            logs = OUT / 'logs' / v['name']
            logs.mkdir(parents=True, exist_ok=True)
            env = comparison.environment(config)
            cmd = ['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                   '--prefix=' + str(Path.home() / 'tools/vortex')]
            code, _ = comparison.execute(cmd, build, env, logs / 'configure.log')
            assert code == 0, v['name'] + ': configure failed'
            for directory in ('hw', 'runtime/stub', 'kernel'):
                code, _ = comparison.execute(['make', '-C', directory], build, env,
                    logs / (directory.replace('/', '_') + '.log'))
                assert code == 0, v['name'] + ': prerequisite failed: ' + directory
            v.update(build=str(build), config=str(config), configs=' '.join(tokens),
                     config_sha256=comparison.digest(config), measurements=[],
                     removed_defines=sorted(remove))
            variants.append(v)
            print('PREPARED', v['name'], flush=True)
        state = dict(current=original['current'], variants=variants,
                     metric='GEMM node total_cycles', repetitions=1,
                     purpose='Matched old/current C3 with request and response stream xbar; Omega records remain separate.')
        comparison.save(state_file, state)
    artifacts = OUT / 'artifacts'
    if not artifacts.exists():
        artifacts.symlink_to(HERE / 'artifacts', target_is_directory=True)
    for v in state['variants']:
        if not any(e['passed'] for e in v['measurements']):
            comparison.measure(state, v, 1)
    report(state)


def report(state):
    original = json.loads((HERE / 'summary.json').read_text())
    old_by_name = {v['name']: v for v in original['variants']}
    rows = []
    lines = ['# C3 M256 stream xbar comparison', '',
        'M=K=N=256, q32, t0, d0, r1; `xrt-vcs-sim --perf 3`. One valid run per variant.',
        'Only request/response Omega defines were removed from the matched historical configuration.',
        'Internal ACC remains enabled; host/kernel binaries are identical to the Omega comparison.', '',
        '| RTL | Stream node cycles | Compute cycles | Omega node cycles | Stream vs Omega |',
        '| --- | ---: | ---: | ---: | ---: |']
    for v in state['variants']:
        e = next(e for e in v['measurements'] if e['passed'])
        omega = next((e['total_cycles'] for e in old_by_name[v['name']]['measurements'] if e['passed']), None)
        row = dict(variant=v['name'], node=e['total_cycles'], compute=e['compute_cycles'], omega=omega)
        rows.append(row)
        delta = f'{100 * (row["node"] / omega - 1):+.3f}%' if omega else 'unavailable'
        lines.append(f'| {v["label"]} | {row["node"]} | {row["compute"]} | {omega or "—"} | {delta} |')
    lines += ['', '| Stream xbar comparison | Cycle delta | Change |', '| --- | ---: | ---: |']
    for a, b in ((0, 1), (1, 2), (0, 2)):
        before, after = rows[a], rows[b]
        lines.append(f'| {before["variant"]} → {after["variant"]} | {after["node"]-before["node"]:+} | {100*(after["node"]/before["node"]-1):+.3f}% |')
    lines += ['', 'All runs passed correctness and artifact/source hash checks. Single samples do not measure run-to-run variability.',
        'This compares RTL cycles, not FPGA Fmax or wall-clock hardware latency.',
        'Removing both Omega defines changes request and response fabrics together; it does not isolate individual ordering mechanisms.',
        'Product RTL and repository configs were not edited. Generated configs/builds are isolated under build_paper_vs_current_sources.', '']
    (OUT / 'results.md').write_text('\n'.join(lines))
    print('COMPLETE: 3/3 stream xbar measurements passed', flush=True)


if __name__ == '__main__':
    main()
