#!/usr/bin/env python3
"""Validate repeated hardware logs and compare smoke cycles without claiming fidelity."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def walk(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def collect(repo, directory, case_set='smoke'):
    reference = json.loads((Path(__file__).parent / f'reference-{case_set}-results.json').read_text())
    app = repo / 'build_hbm_hardware_reference/tests/regression/fpint_gemm_ffn_hw'
    hashes = {name: sha(app / name) for name in ('fpint_gemm_ffn_hw', 'kernel.vxbin')}
    if hashes != reference['program_sha256']:
        raise ValueError('Hardware and simulation program hashes differ')
    samples, comparisons = [], []
    shapes = ((16, 16, 16), (16, 16, 64)) if case_set == 'smoke' else ((16, 16, 256), (64, 64, 64))
    if case_set == 'longk':
        shapes = ((16, 16, 4096),)
    for m, n, k in shapes:
        case_id = f'gemm{m}x{n}x{k}'
        label = str(k) if case_set == 'smoke' else f'{m}x{n}x{k}'
        for rep in range(6):
            log = directory / f'gemm{label}_{rep}.log'
            board = directory / f'gemm{label}_{rep}_board.json'
            text = log.read_text()
            perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
            if len(perf) != 1 or not re.search(r'^PASSED$', text, re.M) or re.search(r'FAILED|Fatal:', text):
                raise ValueError(f'Invalid workload result: {log}')
            device = json.loads(board.read_text())['devices'][0]
            uuids = {item['xclbin_uuid'].lower() for item in walk(device) if 'xclbin_uuid' in item}
            clocks = {item['id']: int(item['freq_mhz']) for item in walk(device) if 'freq_mhz' in item}
            if uuids != {'04277889-d0a3-bd1d-c32e-72ef96e153c3'}:
                raise ValueError(f'Wrong loaded image: {board}: {uuids}')
            if clocks.get('DATA_CLK') != 100 or clocks.get('hbm_aclk') != 450:
                raise ValueError(f'Clock mismatch: {board}: {clocks}')
            if device['device_status'] != 'HEALTHY':
                raise ValueError(f'Unhealthy device: {board}')
            temps = sorted({float(item['temperature_C']) for item in walk(device) if 'temperature_C' in item})
            instrs, cycles = map(int, perf[0])
            samples.append({'case': case_id, 'repetition': rep, 'warmup': rep == 0,
                            'kernel_cycles': cycles, 'instructions': instrs, 'output_check': 'passed',
                            'reported_clocks_mhz': clocks, 'memory_temperatures_C': temps,
                            'log': str(log.relative_to(repo)), 'log_sha256': sha(log),
                            'board_report': str(board.relative_to(repo)), 'board_sha256': sha(board)})
        measured = [s['kernel_cycles'] for s in samples if s['case'] == case_id and not s['warmup']]
        median = statistics.median(measured)
        comparison = {'case': case_id, 'hardware_count': len(measured),
                      'hardware_median_cycles': median, 'hardware_min_cycles': min(measured),
                      'hardware_max_cycles': max(measured), 'hardware_stdev_cycles': statistics.pstdev(measured),
                      'hardware_range_over_median': (max(measured)-min(measured))/median if median else None,
                      'models': {}}
        for mode in ('baseline', 'document'):
            model = [s['kernel_cycles'] for s in reference['results'] if s['case'] == comparison['case'] and s['mode'] == mode]
            value = statistics.median(model)
            error = (value-median)/median if median else None
            comparison['models'][mode] = {'median_cycles': value, 'signed_relative_error': error,
                                          'absolute_relative_error': abs(error) if error is not None else None}
        comparisons.append(comparison)
    return {'status': 'exploratory_smoke_not_acceptance', 'program_sha256': hashes,
            'samples': samples, 'comparisons': comparisons,
            'policy': 'One excluded warm-up per shape, then five fresh host processes in one exclusive FPGA GRES allocation; each program uses normal runtime reset and fresh BOs.',
            'limitations': ['Post-run clock/UUID/temperature samples, not continuous telemetry.',
                            'No claim of absent transient throttling; no dedicated throttling metric collected.',
                            'No intended error tolerance established and no held-out cases evaluated.',
                            'Kernel counters include setup and MMIO polling; not isolated DRAM latency.',
                            'Clock connection and operating-frequency evidence are documented separately.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case-set', choices=('smoke', 'explore', 'longk'), default='smoke')
    args = parser.parse_args()
    result = collect(args.repo.resolve(), args.directory.resolve(), args.case_set)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result['comparisons'], indent=2))
