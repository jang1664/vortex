#!/usr/bin/env python3
"""Collect software phase snapshots, never substitute for original benchmarks."""
import argparse
import json
from pathlib import Path
import re
import statistics
from collect_hardware_smoke import sha, walk


def collect(repo, hardware):
    paths = [repo / f'{build}/tests/regression/reference_phase' for build in
             ('build_hbm_reference', 'build_hbm_hardware_reference')]
    hashes = [{name: sha(p / name) for name in ('reference_phase', 'kernel.vxbin')} for p in paths]
    if hashes[0] != hashes[1]:
        raise ValueError('Diagnostic binaries differ')
    samples, summary = [], {}
    for mode in ('document', 'hardware'):
        summary[mode] = {}
        for polls in (1, 256):
            measured = []
            for rep in range(6) if mode == 'hardware' else (1, 2):
                log = (hardware / f'phase{polls}_{rep}.log' if mode == 'hardware' else
                       repo / f'build_hbm_reference_document/phase_document_{polls}_repeat{rep}.log')
                text = log.read_text()
                phase = re.findall(r'PHASE_RESULT polls=(\d+) entry=(\d+) returned=(\d+) body=(\d+)', text)
                perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
                if len(phase) != 1 or len(perf) != 1 or 'PHASE_CONTROL_PASS' not in text or 'PHASE_ERROR' in text:
                    raise ValueError(f'Failed phase diagnostic: {log}')
                count, entry, returned, body = map(int, phase[0])
                instrs, total = map(int, perf[0])
                if count != polls or body != returned-entry or not 0 < entry <= returned <= total:
                    raise ValueError('Invalid phase ordering')
                row = {'mode': mode, 'polls': polls, 'repetition': rep, 'warmup': mode == 'hardware' and rep == 0,
                       'entry': entry, 'body': body, 'post_body': total-returned, 'total': total,
                       'instructions': instrs, 'log': str(log.relative_to(repo)), 'log_sha256': sha(log)}
                if mode == 'hardware':
                    report = hardware / f'phase{polls}_{rep}_board.json'
                    device = json.loads(report.read_text())['devices'][0]
                    clocks = {v['id']: int(v['freq_mhz']) for v in walk(device) if 'freq_mhz' in v}
                    uuids = {v['xclbin_uuid'].lower() for v in walk(device) if 'xclbin_uuid' in v}
                    if device['device_status'] != 'HEALTHY' or clocks.get('DATA_CLK') != 100 or clocks.get('hbm_aclk') != 450 or uuids != {'04277889-d0a3-bd1d-c32e-72ef96e153c3'}:
                        raise ValueError('Hardware identity/clock mismatch')
                    row.update(board=str(report.relative_to(repo)), board_sha256=sha(report))
                else:
                    sim = log.with_name(log.stem + '_simv.log')
                    simtext = sim.read_text()
                    if 'Fatal:' in simtext or '$finish at simulation time' not in simtext:
                        raise ValueError('Simulation failed/incomplete')
                    row.update(sim_log=str(sim.relative_to(repo)), sim_sha256=sha(sim))
                samples.append(row)
                if not row['warmup']:
                    measured.append(row)
            summary[mode][str(polls)] = {field: statistics.median(r[field] for r in measured)
                                         for field in ('entry', 'body', 'post_body', 'total')}
    return {'status': 'instrumented_software_diagnostic', 'program_sha256': hashes[0], 'samples': samples,
            'median_cycles': summary,
            'limitations': ['Different diagnostic binary/layout from the unchanged GEMM benchmark.',
                            'Entry snapshot follows a five-instruction main prologue including stack stores.',
                            'Snapshot instructions and result stores perturb execution; do not subtract offsets from acceptance metrics.',
                            'Original poll path checks STATUS_OK but no GEMM result is computed.']}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', required=True, type=Path)
    p.add_argument('--hardware-directory', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    result = collect(a.repo.resolve(), a.hardware_directory.resolve())
    a.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result['median_cycles'], indent=2))
