#!/usr/bin/env python3
"""Reproduce matched M256 paper/current RTL measurements without editing product files."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import statistics
import subprocess
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CURRENT = '18ab7f92b8f6e7f328f13d2c2513a23a21f5904e'
CASES = {
    'C1': ('93f4ae97d', 'tcu_94c5b39919', 'sgemm_tcu'),
    'C3': ('93f4ae97d', '9600db3a37', 'fpint_gemm_ffn_hw_naive'),
    'C4': ('391b45d39', '64300e5119', 'fpint_gemm_ffn_hw'),
}
REPETITIONS = {'C1': 1, 'C3': 1, 'C4': 3}
PATHS = ['configure', 'config.mk.in', 'Makefile.in', 'ci', 'configs', 'hw',
         'sim', 'runtime', 'kernel', 'tests', 'perf']


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def extract(ref, dest, paths):
    with tarfile.open(fileobj=io.BytesIO(git('archive', ref, *paths))) as archive:
        archive.extractall(dest)


def execute(cmd, cwd, env, log, timeout=300):
    start = time.monotonic()
    with log.open('w') as stream:
        result = subprocess.run(['timeout', '--signal=TERM', '--kill-after=10s',
                                 str(timeout), *cmd], cwd=cwd, env=env,
                                stdout=stream, stderr=subprocess.STDOUT)
    return result.returncode, round(time.monotonic() - start, 2)


def verify_snapshot(case):
    ref, suffix, _ = CASES[case]
    snapshot = Path('/opt/vortex_fpga_bins/fpint') / ('xrt_hw_u55c_c_f100_fpint_' + suffix)
    lines = (snapshot / 'sources.txt').read_text().splitlines()
    flags = [s for s in lines if s.startswith('+define+') or
             (s.startswith('+incdir+') and '/third_party/' in s)]
    files = git('ls-tree', '-r', '--name-only', ref, 'hw/rtl').decode().splitlines()
    byname = {}
    for name in files:
        byname.setdefault(Path(name).name, []).append(name)
    overrides = {'VX_gemm_unit.sv': 'hw/rtl/core/gemm/VX_gemm_unit.sv',
                 'VX_gemm_unit_top.sv': 'hw/rtl/core/gemm/VX_gemm_unit_top.sv',
                 'VX_utils_pkg.sv': 'hw/rtl/verification/VX_utils_pkg.sv',
                 'vortex_afu.vh': 'hw/rtl/afu/xrt/vortex_afu.vh'}
    records, excluded = [], []
    for target in sorted((snapshot / 'src').iterdir()):
        if target.suffix not in ('.v', '.sv', '.vh'):
            continue
        candidates = byname.get(target.name, [])
        if not candidates:
            excluded.append(target.name)
            continue
        source = overrides.get(target.name)
        if source is None:
            assert len(candidates) == 1, candidates
            source = candidates[0]
        data = git('show', f'{ref}:{source}')
        if target.suffix in ('.sv', '.v'):
            pre = subprocess.run(['verilator', '-E', '-P', '-sv',
                                  '-I' + str(snapshot / 'src'), *flags, '/dev/stdin'],
                                 input=data, capture_output=True)
            if pre.returncode:
                raise RuntimeError(pre.stderr.decode()[:2000])
            data = pre.stdout
        equal = data == target.read_bytes()
        records.append(dict(source=source, snapshot_sha256=digest(target), equal=equal))
    result = dict(case=case, equivalent_rtl_commit=git('rev-parse', ref).decode().strip(),
                  snapshot=str(snapshot), matched=sum(r['equal'] for r in records),
                  files=records, excluded_external=excluded,
                  manifest_sha256=digest(snapshot / 'manifest.json'),
                  sources_sha256=digest(snapshot / 'sources.txt'))
    save(HERE / f'snapshot_{case}.json', result)
    assert records and all(r['equal'] for r in records), f'{case}: snapshot mismatch'
    print(f'SNAPSHOT {case}: {len(records)} identical', flush=True)
    # Retain all actual hardware defines except synthesis and add common instrumentation.
    defines = list(dict.fromkeys(s.replace('+define+', '-D', 1) for s in lines
                                if s.startswith('+define+') and s != '+define+SYNTHESIS'))
    if case == 'C1':
        # SYNTHESIS selects this implicitly in the saved FPGA build. Removing
        # SYNTHESIS without pinning it would silently select the TCU DPI model.
        defines.append('-DTCU_DSP')
    return list(dict.fromkeys([*defines, '-DPERF_ENABLE', '-DDISABLE_FSDB']))


def environment(config):
    env = os.environ.copy()
    for key in ('CONFIGS', 'DEBUG', 'DEBUG_AXI', 'PERF', 'FSDB_DUMP', 'GUI', 'MAKEFLAGS',
                'VORTEX_HOME', 'VORTEX_RT_PATH', 'VORTEX_KN_PATH', 'FPGA_BIN_DIR',
                'RISCV_TOOLCHAIN_PATH', 'RISCV_SYSROOT', 'LIBC_VORTEX', 'LIBCRT_VORTEX'):
        env.pop(key, None)
    env.update(CC='/usr/bin/gcc', CXX='/usr/bin/g++', VCS_CPPFLAGS='-DDEBUG_LEVEL=0',
               THIRD_PARTY_DIR=str(ROOT / 'third_party'),
               SIMLIB_DIR=str(ROOT / 'build/vcs_simlib'),
               XILINX_IP_DIR=str(ROOT / 'build/sim/xrtsim_vcs/xilinx_ip'),
               SGEMM_TCU_VARIANT='b_colmajor', DRAM_REQ_STALL_P_ENTER_PCT='0',
               DRAM_RSP_STALL_P_ENTER_PCT='0', DRAM_REQ_STALL_P_EXIT_PCT='50',
               DRAM_RSP_STALL_P_EXIT_PCT='50', DRAM_STALL_SEED='1234')
    env['VCS_SIMV_FLAGS'] = ('+DRAM_REQ_STALL_P_ENTER_PCT=0 +DRAM_RSP_STALL_P_ENTER_PCT=0 '
                             '+DRAM_REQ_STALL_P_EXIT_PCT=50 +DRAM_RSP_STALL_P_EXIT_PCT=50 '
                             '+DRAM_STALL_SEED=1234')
    env['MAKEFLAGS'] = 'FSDB_DUMP= ' + ' '.join('--old-file=' + str(p) for p in (
        ROOT / 'build/sim/xrtsim_vcs/xilinx_ip/.generated.stamp',
        ROOT / 'build/vcs_simlib/synopsys_sim.setup'))
    # Explicitly source the generated historical config before every build/run.
    env['CONFIGS'] = subprocess.check_output(
        ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'config', str(config)],
        env=env, text=True)
    return env


def prepare(work):
    work.mkdir(parents=True, exist_ok=True)
    variants = []
    for case, (baseline, _, app) in CASES.items():
        defines = verify_snapshot(case)
        for label in (['old', 'current'] if case == 'C1' else ['old', 'off', 'on']):
            name = case + '_' + label
            source = work / name
            if source.exists():
                source.rename(work / (name + '_setup_attempt_' + str(int(time.time()))))
            source.mkdir()
            extract(CURRENT, source, PATHS)
            if label == 'old':
                # Move the current subtree aside so removed/new files cannot leak into baseline.
                (source / 'hw/rtl').rename(source / 'hw/rtl_current_unused')
                extract(baseline, source, ['hw/rtl'])
            (source / ('tests/regression/' + app)).rename(source / ('tests/regression/' + app + '_unused'))
            extract(baseline, source, ['tests/regression/' + app])
            (source / 'third_party').symlink_to(ROOT / 'third_party', target_is_directory=True)
            tokens = defines.copy()
            if case == 'C3' and label != 'old':
                tokens.append('-DGEMM_NAIVE_USE_ACC_MEM')
            if label == 'on':
                tokens.append('-DGEMM_SLR_PIPELINE')
            config = source / 'configs/paper_comparison.sh'
            config.write_text('export CONFIGS=' + shlex.quote(' '.join(tokens)) + '\n')
            out = HERE / 'logs' / name
            out.mkdir(parents=True, exist_ok=True)
            build = source / 'build'
            build.mkdir()
            env = environment(config)
            cmd = ['../configure', '--xlen=64', '--tooldir=/opt/vortex',
                   '--prefix=' + str(Path.home() / 'tools/vortex')]
            code, _ = execute(cmd, build, env, out / 'configure.log')
            assert code == 0, f'{name}: configure failed'
            # Runtime stub and kernel library are prerequisites of the blackbox flow.
            for directory in ('hw', 'runtime/stub', 'kernel'):
                code, _ = execute(['make', '-C', directory], build, env,
                                  out / (directory.replace('/', '_') + '.log'))
                assert code == 0, f'{name}: {directory} failed'
            v = dict(name=name, case=case, label=label, source=str(source), build=str(build),
                     app=app, config=str(config), configs=' '.join(tokens),
                     config_sha256=digest(config), rtl_commit=baseline if label == 'old' else CURRENT,
                     app_commit=baseline, measurements=[])
            v['source_sha256'] = {str(p.relative_to(source)): digest(p)
                                  for directory in ('hw/rtl', 'sim/xrtsim_vcs', 'runtime', 'kernel', 'tests/regression/' + app)
                                  for p in sorted((source / directory).rglob('*')) if p.is_file()}
            variants.append(v)
            print(f'PREPARED {name}', flush=True)
    save(HERE / 'summary.json', dict(current=CURRENT, work=str(work), variants=variants))


def measure(state, v, repetition):
    source, build = Path(v['source']), Path(v['build'])
    out = HERE / 'logs' / v['name']
    env = environment(Path(v['config']))
    appdir = build / 'tests/regression' / v['app']
    artifacts = [v['app'], 'kernel.vxbin', 'kernel.elf']
    common = HERE / 'artifacts' / v['case']
    if common.exists():
        for filename in artifacts:
            shutil.copy2(common / filename, appdir / filename)
        env['MAKEFLAGS'] += ' ' + ' '.join('--old-file=' + f for f in artifacts)
    args = v.get('args', '-m 256 -k 256 -n 256' + ('' if v['case'] == 'C1' else ' -q 32 -t 0 -d 0 -r 1'))
    command = [str(source / 'ci/run_black.sh'), 'xrt-vcs-sim', '--app', v['app'],
               '--args', args, '--perf', '1' if v['case'] == 'C1' else '3']
    v['command'] = command
    v['simulation_environment'] = {k: env[k] for k in (
        'MAKEFLAGS', 'VCS_SIMV_FLAGS', 'VCS_CPPFLAGS', 'SIMLIB_DIR', 'XILINX_IP_DIR',
        'THIRD_PARTY_DIR', 'CC', 'CXX', 'SGEMM_TCU_VARIANT')}
    previous = [e for e in v['measurements'] if e['repetition'] == repetition]
    first_attempt = max((e['attempt'] for e in previous), default=0) + 1
    limits = (1800,) if previous or v.get('long_run_required') else (300, 1800)
    for attempt, limit in enumerate(limits, first_attempt):
        print(f'START {v["name"]} repetition={repetition} attempt={attempt}', flush=True)
        log = out / f'run{repetition}_attempt{attempt}.log'
        code, elapsed = execute(command, build, env, log, limit)
        simlog = build / 'sim/xrtsim_vcs/simv.log'
        saved = out / f'run{repetition}_attempt{attempt}.simv.log'
        if simlog.exists():
            shutil.copy2(simlog, saved)
        text = log.read_text(errors='replace')
        diagnostics = text + (saved.read_text(errors='replace') if saved.exists() else '')
        perf = [s for s in text.splitlines() if s.startswith('PERF:')]
        counters = re.findall(r'PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)', text)
        core = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
        compute = re.findall(r'PERF: compute_cycles=(\d+) stall_cycles=(\d+) mac_count=(\d+)', text)
        fatal = bool(re.search(r'Fatal:|Error-|^ERROR[: ]|Assertion.*fail|\$fatal', diagnostics, re.M))
        passed = code == 0 and 'PASSED' in text and not fatal and len(core if v['case'] == 'C1' else counters) == 1
        entry = dict(repetition=repetition, attempt=attempt, returncode=code, seconds=elapsed,
                     timeout=limit, passed=passed, fatal=fatal, log=str(log), simlog=str(saved), perf=perf)
        if core:
            entry.update(zip(('instrs', 'core_cycles'), map(int, core[-1])))
        if counters:
            entry.update(zip(('jobs', 'total_cycles', 'busy_cycles'), map(int, counters[-1])))
        if compute:
            entry.update(zip(('compute_cycles', 'stall_cycles', 'mac_count'), map(int, compute[-1])))
        v['measurements'].append(entry)
        save(HERE / 'summary.json', state)
        print(f'END {v["name"]} pass={passed} rc={code} core={core} node={counters}', flush=True)
        if code != 124:
            break
        assert re.search(r'Compiling|Parsing|g\+\+|gcc|V C S|cycles|vhdlan', diagnostics), 'Timeout without progress'
    assert passed, f'{v["name"]}: failed; inspect {log}'
    try:
        actual = {f: digest(appdir / f) for f in artifacts}
        if common.exists():
            assert actual == {f: digest(common / f) for f in artifacts}, 'Application rebuilt or changed'
        else:
            common.mkdir(parents=True)
            for filename in artifacts:
                shutil.copy2(appdir / filename, common / filename)
        v['artifact_sha256'] = actual
        for filename, expected in v['source_sha256'].items():
            assert digest(source / filename) == expected, f'Source mutated: {filename}'
        entry['integrity_verified'] = True
    except Exception as error:
        entry.update(passed=False, integrity_error=str(error))
        save(HERE / 'summary.json', state)
        raise
    save(HERE / 'summary.json', state)


def run(cases=None):
    state = json.loads((HERE / 'summary.json').read_text())
    for repetition in range(1, 4):
        for case in CASES:
            if cases and case not in cases:
                continue
            if repetition > REPETITIONS[case]:
                continue
            variants = [v for v in state['variants'] if v['case'] == case]
            shift = (repetition - 1) % len(variants)
            for v in variants[shift:] + variants[:shift]:
                if not any(e['passed'] and e['repetition'] == repetition for e in v['measurements']):
                    measure(state, v, repetition)
    state['target_repetitions'] = REPETITIONS
    save(HERE / 'summary.json', state)
    if any(sum(e['passed'] for e in v['measurements']) != REPETITIONS[v['case']] for v in state['variants']):
        print('Selected measurements complete; other variants remain pending', flush=True)
        return
    for v in state['variants']:
        key = 'core_cycles' if v['case'] == 'C1' else 'total_cycles'
        values = [e[key] for e in v['measurements'] if e['passed']]
        assert len(values) == REPETITIONS[v['case']]
        v['statistics'] = dict(metric=key, n=len(values), median=statistics.median(values), min=min(values), max=max(values))
    save(HERE / 'summary.json', state)
    report(state)
    print('COMPLETE: 14/14 measurements passed', flush=True)


def report(state):
    lines = ['# M256 paper/current RTL comparison', '',
             f'Current commit: `{CURRENT}`. All 14 measurements passed correctness checks.', '',
             'M=K=N=256; historical hardware configs; identical host/kernel binaries within each backend.',
             'C1/C3: one run per variant (user-approved reduced scope). C4: three independent runs per variant.',
             'Positive cycle change means slower. C1/C3 have no measured variability range.', '',
             '| Backend | RTL | Run 1 | Run 2 | Run 3 | Median | Min–max |',
             '| --- | --- | ---: | ---: | ---: | ---: | --- |']
    for v in state['variants']:
        s = v['statistics']
        values = [e[s['metric']] for e in v['measurements'] if e['passed']]
        values += ['—'] * (3 - len(values))
        span = f'{s["min"]}–{s["max"]}' if s['n'] > 1 else 'single run'
        lines.append(f'| {v["case"]} | {v["label"]} | ' + ' | '.join(map(str, values))
                     + f' | {s["median"]} | {span} |')
    lines += ['', 'C1: core cycles (`--perf 1`). C3/C4: GEMM node total cycles (`--perf 3`).',
              'These metrics are not directly comparable across backends.', '',
              '| Backend | Comparison | Cycle delta | Change | Speedup |',
              '| --- | --- | ---: | ---: | ---: |']
    comparisons = []
    for case in CASES:
        vv = {v['label']: v for v in state['variants'] if v['case'] == case}
        pairs = [('old', 'current')] if case == 'C1' else [('old', 'off'), ('off', 'on'), ('old', 'on')]
        for a, b in pairs:
            sa, sb = vv[a]['statistics'], vv[b]['statistics']
            av, bv = sa['median'], sb['median']
            entry = dict(case=case, before=a, after=b, delta=bv-av,
                         percent=100*(bv-av)/av, speedup=av/bv,
                         ranges_overlap=(max(sa['min'],sb['min']) <= min(sa['max'],sb['max'])) if REPETITIONS[case] > 1 else None)
            comparisons.append(entry)
            lines.append(f'| {case} | {a} → {b} | {bv-av:+} | {entry["percent"]:+.3f}% | {av/bv:.4f}× |')
    state['comparisons'] = comparisons
    save(HERE / 'summary.json', state)
    lines += ['', '## Validation and limits', '',
              '- Baseline snapshots matched exactly after preprocessing: C1 281, C3 267, C4 269 repository RTL files.',
              '- Historical commits identify equivalent RTL; the binary manifests contain no original checkout revision.',
              '- Same app binary SHA-256 across all variants of each backend; source hashes and configs are in `summary.json`.',
              '- Added performance instrumentation to both revisions; removed SYNTHESIS; disabled FSDB and additional DRAM stalls.',
              '- Explicit TCU_DSP on both C1 revisions preserves the FPGA datapath after removing SYNTHESIS (default simulation would select TCU_DPI).',
              '- C1 includes software and data movement. C3/C4 total-cycle definitions differ between backends.',
              '- C3 current uses internal ACC explicitly; external LMEM PSUM is outside this experiment.',
              '- Overlapping min–max ranges do not establish a small performance change.',
              '- Actual FPGA time, timing closure and maximum clock frequency were not measured.',
              '- Reproduction: `README.md`; commands, counters and hashes: `summary.json`; raw output: `logs/`.', '']
    (HERE / 'results.md').write_text('\n'.join(lines))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--work', type=Path, default=ROOT / 'build_paper_vs_current_sources')
    parser.add_argument('--cases', nargs='+', choices=list(CASES))
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.work)
    else:
        run(args.cases)
