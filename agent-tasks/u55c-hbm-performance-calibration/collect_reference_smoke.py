#!/usr/bin/env python3
"""Collect bounded historical smoke evidence; never infer hardware agreement."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def collect(repo, case_set='smoke'):
    logs = repo / 'build_hbm_reference_document'
    stages = repo / 'build_hbm_reference/sim/xrtsim_vcs'
    app = repo / 'build_hbm_reference/tests/regression/fpint_gemm_ffn_hw'
    modes = {}
    for mode, prefix in [('baseline', 'archived-baseline'), ('document', 'archived-document')]:
        stage = stages / f'{prefix}-guarded-{"add" if case_set == "longk" else "mul"}'
        manifest = json.loads((stage / 'u55c_model_manifest.json').read_text())
        modes[mode] = {
            'stage': str(stage.relative_to(repo)),
            'sha256': {name: sha(stage / name) for name in
                       ('simv', 'libxrtsim_vcs.so', 'u55c_model_manifest.json', 'Makefile.reference')},
            'manifest': manifest,
        }
    rows = []
    shapes = ((16, 16, 16), (16, 16, 64)) if case_set == 'smoke' else ((16, 16, 256), (64, 64, 64))
    if case_set == 'longk':
        shapes = ((16, 16, 4096),)
    for mode in modes:
        for m, n, k in shapes:
            for rep in (1, 2):
                stem = (f'baseline_guarded_gemm{k}_{rep}' if mode == 'baseline' else
                        f'archived_guarded_mul_gemm{k}' + ('_repeat' if rep == 2 else ''))
                if case_set == 'explore':
                    stem = f'explore_{mode}_gemm{m}x{n}x{k}_{rep}'
                if case_set == 'longk':
                    stem = f'longk_guarded_add_{rep}' if mode == 'document' else f'longk_baseline_add_{rep}'
                host, sim = logs / f'{stem}.log', logs / f'{stem}_simv.log'
                text, simtext = host.read_text(), sim.read_text()
                perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
                if len(perf) != 1 or not re.search(r'^PASSED$', text, re.M):
                    raise ValueError(f'Missing unambiguous successful result: {host}')
                if re.search(r'Fatal:|FAILED', text + simtext) or '$finish at simulation time' not in simtext:
                    raise ValueError(f'Failed or incomplete simulation: {sim}')
                instrs, cycles = map(int, perf[0])
                hz = modes[mode]['manifest']['logic_freq_hz']
                rows.append({'mode': mode, 'case': f'gemm{m}x{n}x{k}', 'repetition': rep,
                             'args': f'-m {m} -n {n} -k {k} -q 32 -r 1',
                             'output_check': 'passed', 'instructions': instrs, 'kernel_cycles': cycles,
                             'device_time_ns': cycles * 1_000_000_000 / hz,
                             'host_log': str(host.relative_to(repo)), 'host_log_sha256': sha(host),
                             'sim_log': str(sim.relative_to(repo)), 'sim_log_sha256': sha(sim)})
    return {'status': 'simulation_smoke_only', 'modes': modes, 'results': rows,
            'program_sha256': {name: sha(app / name) for name in ('fpint_gemm_ffn_hw', 'kernel.vxbin')},
            'hardware_results': None, 'hardware_relative_errors': None,
            'limitations': ['Not hardware-calibrated; no tolerance established.',
                            'These GEMM shapes do not establish isolated HBM bandwidth or zero-load latency.',
                            'Whole-kernel counters include program polling; not isolated GEMM engine cycles.',
                            'Device time is cycles divided by modeled kernel frequency, not host wall time.',
                            'Hashes identify current files; baseline before/after checks are recorded separately.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case-set', choices=('smoke', 'explore', 'longk'), default='smoke')
    args = parser.parse_args()
    result = collect(args.repo.resolve(), args.case_set)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(f"Collected {len(result['results'])} successful simulation runs; hardware comparison pending")
