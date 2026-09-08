#!/usr/bin/env python3
"""Compare fixed-count polling; explicitly not GEMM output correctness."""
import argparse
import json
from pathlib import Path
import re
import statistics
from collect_hardware_smoke import sha, walk


def collect(repo, hardware):
    rows, summary = [], {}
    logs = repo / 'build_hbm_reference_document'
    for mode in ('baseline', 'document', 'hardware'):
        summary[mode] = {}
        for count in (1, 256):
            cycles = []
            for rep in range(6) if mode == 'hardware' else (1, 2):
                log = (hardware / f'gemmpoll{count}_{rep}.log' if mode == 'hardware'
                       else logs / f'poll_{mode}_{count}_{rep}.log')
                text = log.read_text()
                perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
                if len(perf) != 1 or '[POLL-ONLY MODE]' not in text or 'Power mode: skipping verification' not in text:
                    raise ValueError(f'Not a completed poll diagnostic: {log}')
                if not re.search(r'^PASSED$', text, re.M) or re.search(r'FAILED|Fatal:|Kernel failed', text):
                    raise ValueError(f'Control status failed: {log}')
                instructions, value = map(int, perf[0])
                row = {'mode': mode, 'poll_count': count, 'repetition': rep,
                       'warmup': mode == 'hardware' and rep == 0, 'cycles': value,
                       'instructions': instructions, 'output_verification': 'intentionally_skipped',
                       'control_status': 'normal_completion', 'log': str(log.relative_to(repo)), 'sha256': sha(log)}
                if mode == 'hardware':
                    board = hardware / f'gemmpoll{count}_{rep}_board.json'
                    device = json.loads(board.read_text())['devices'][0]
                    uuids = {v['xclbin_uuid'].lower() for v in walk(device) if 'xclbin_uuid' in v}
                    clocks = {v['id']: int(v['freq_mhz']) for v in walk(device) if 'freq_mhz' in v}
                    if uuids != {'04277889-d0a3-bd1d-c32e-72ef96e153c3'} or clocks.get('DATA_CLK') != 100 or clocks.get('hbm_aclk') != 450:
                        raise ValueError('Hardware profile mismatch')
                    row.update(board_report=str(board.relative_to(repo)), board_sha256=sha(board), clocks_mhz=clocks)
                else:
                    sim = log.with_name(log.stem + '_simv.log')
                    simtext = sim.read_text()
                    if 'Fatal:' in simtext or '$finish at simulation time' not in simtext:
                        raise ValueError(f'Simulator incomplete: {sim}')
                    row.update(sim_log=str(sim.relative_to(repo)), sim_sha256=sha(sim))
                rows.append(row)
                if not row['warmup']:
                    cycles.append(value)
            summary[mode][str(count)] = {'median': statistics.median(cycles), 'min': min(cycles),
                                          'max': max(cycles), 'samples': len(cycles)}
        summary[mode]['incremental_cycles_per_poll'] = (summary[mode]['256']['median'] - summary[mode]['1']['median']) / 255
    gap = {str(n): summary['hardware'][str(n)]['median'] - summary['document'][str(n)]['median'] for n in (1, 256)}
    return {'status': 'control_diagnostic_only', 'samples': rows, 'summary': summary,
            'hardware_minus_document_cycles': gap,
            'limitations': ['No GEMM job submitted; output verification deliberately skipped.',
                            'Two counts estimate marginal polling cost, not isolated HBM latency.',
                            'Do not subtract this offset from GEMM acceptance results.',
                            'Residual can include instruction/data-cache startup and control-path work.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--hardware-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = collect(args.repo.resolve(), args.hardware_directory.resolve())
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'summary': result['summary'], 'gaps': result['hardware_minus_document_cycles']}, indent=2))
