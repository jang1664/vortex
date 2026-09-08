#!/usr/bin/env python3
"""Validate frozen candidate held-out replays and matched hardware samples."""
import argparse
import json
from pathlib import Path
import re
import statistics
from collect_hardware_smoke import sha, walk


def collect(repo, hardware, mode='candidate'):
    stages = {'candidate': 'archived-diagnostic-read-plus400ns',
              'baseline': 'archived-baseline-guarded-add',
              'document': 'archived-document-guarded-add'}
    if mode not in stages:
        raise ValueError('Unknown model mode')
    task = Path(__file__).resolve().parent
    for line in (task/'held-out-freeze.sha256').read_text().splitlines():
        digest, path = line.split(None, 1)
        if sha(repo/path) != digest:
            raise ValueError(f'Frozen artifact changed: {path}')
    app = repo/'build_hbm_reference/tests/regression/fpint_gemm_ffn_hw'
    hwapp = repo/'build_hbm_hardware_reference/tests/regression/fpint_gemm_ffn_hw'
    for name in ('fpint_gemm_ffn_hw', 'kernel.vxbin'):
        if sha(app/name) != sha(hwapp/name):
            raise ValueError('Program identity mismatch')
    stage = repo/'build_hbm_reference/sim/xrtsim_vcs'/stages[mode]
    expected = {'sim/xrtsim_vcs/simv': sha(stage/'simv'),
                'sim/xrtsim_vcs/u55c_model_manifest.json': sha(stage/'u55c_model_manifest.json'),
                'runtime/libxrtsim_vcs.so': sha(stage/'libxrtsim_vcs.so')}
    expected.update({str(app/name): sha(app/name) for name in ('fpint_gemm_ffn_hw', 'kernel.vxbin')})
    samples, comparisons = [], []
    def parse(log):
        text = log.read_text()
        perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)', text)
        if len(perf) != 1 or not re.search(r'^PASSED$', text, re.M) or re.search(r'FAILED|Fatal:|Error-\[', text):
            raise ValueError(f'Invalid result: {log}')
        return tuple(map(int, perf[0]))
    for label, shape in (('h1','16x16x1024'), ('h2','64x64x256'), ('h3','128x128x64')):
        hwcycles, replay = [], []
        for rep in range(6):
            log = hardware/f'gemm{shape}_{rep}.log'
            board = hardware/f'gemm{shape}_{rep}_board.json'
            instrs, cycles = parse(log)
            device = json.loads(board.read_text())['devices'][0]
            uuids = {x['xclbin_uuid'].lower() for x in walk(device) if 'xclbin_uuid' in x}
            clocks = {x['id']: int(x['freq_mhz']) for x in walk(device) if 'freq_mhz' in x}
            if uuids != {'04277889-d0a3-bd1d-c32e-72ef96e153c3'} or clocks.get('DATA_CLK') != 100 or clocks.get('hbm_aclk') != 450 or device['device_status'] != 'HEALTHY':
                raise ValueError(f'Invalid board identity/clock/health: {board}')
            if rep:
                hwcycles.append(cycles)
            samples.append(dict(case=shape, mode='hardware', repetition=rep, warmup=rep==0,
                cycles=cycles, instructions=instrs, log=str(log.relative_to(repo)), sha256=sha(log),
                board=str(board.relative_to(repo)), board_sha256=sha(board)))
        for rep in (1,2):
            stem = repo/'build_hbm_reference_document'/f'heldout_{mode}_{label}_{rep}'
            before = Path(str(stem)+'_before.sha256')
            recorded = {p:d for d,p in (line.split(None,1) for line in before.read_text().splitlines())}
            if recorded != expected:
                raise ValueError(f'Prelaunch hash mismatch: {before}')
            host, sim = Path(str(stem)+'.log'), Path(str(stem)+'_simv.log')
            instrs, cycles = parse(host)
            text = sim.read_text()
            if '$finish at simulation time' not in text or re.search(r'Fatal:|FAILED|Error-\[',text):
                raise ValueError(f'Invalid simulator termination: {sim}')
            replay.append((instrs,cycles))
            samples.append(dict(case=shape, mode=mode, repetition=rep, cycles=cycles,
                instructions=instrs, log=str(host.relative_to(repo)), sha256=sha(host),
                sim=str(sim.relative_to(repo)), sim_sha256=sha(sim)))
        if len(set(replay)) != 1:
            raise ValueError(f'Nondeterministic replay: {shape}')
        median = statistics.median(hwcycles)
        if median <= 0:
            raise ValueError('Invalid hardware cycle denominator')
        error = (replay[0][1]-median)/median
        comparisons.append(dict(case=shape, model_cycles=replay[0][1], hardware_median=median,
            hardware_min=min(hwcycles), hardware_max=max(hwcycles), signed_relative_error=error,
            absolute_relative_error=abs(error), within_10_percent=abs(error)<=0.10))
    return dict(status='heldout_results_not_full_goal_acceptance', mode=mode, tolerance=0.10,
        comparisons=comparisons, samples=samples,
        limitations=['Each model result is collected separately against the same hardware samples.',
                      'Effective delay fit, not physical HBM latency measurement.',
                      'Post-run board reports are not continuous throttling telemetry.',
                      'Primitive provenance and overall acceptance gates remain separate.'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--hardware', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('candidate','baseline','document'), default='candidate')
    args = parser.parse_args()
    result = collect(args.repo.resolve(), args.hardware.resolve(), args.mode)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result['comparisons'], indent=2))
