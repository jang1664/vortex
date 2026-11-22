#!/usr/bin/env python3
"""Profile diagnostic software variants on the unchanged unified-MMIO image."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build_c4_unified_mmio_hw'
ALIAS = 'improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1'
CASES = {
    'llama3-8b_decode_p16_c32': ['--seq-len', '1', '--stage', 'decode', '--past-kv-len', '16', '--cache-capacity', '32'],
    'llama3-8b_decode_p128_c256': ['--seq-len', '1', '--stage', 'decode', '--past-kv-len', '128', '--cache-capacity', '256'],
    'llama3-8b_prefill128': ['--seq-len', '128', '--stage', 'prefill'],
}

parser = argparse.ArgumentParser()
parser.add_argument('variant')
parser.add_argument('--case', action='append', choices=CASES)
parser.add_argument('--backend', default='resident', choices=['resident', 'resident-fp32', 'legacy'])
args = parser.parse_args()
out = Path(__file__).resolve().parent / 'runs' / args.variant
out.mkdir(parents=True, exist_ok=False)
(out / 'source.diff').write_text(subprocess.check_output(
    ['git', 'diff', '--', 'kernel/include/vx_flash_attention.h', 'tests/regression/flash_attn',
     'tests/regression/llama_decoder_C4'], cwd=ROOT, text=True))
report = {}
for case in args.case or CASES:
    target = out / case
    app_args = ['--model', 'llama3-8b', '--batch', '1'] + CASES[case] + [
        '--mode', 'timing', '--attention-backend', args.backend,
        '--fixture', str(ROOT / 'build_c4_sram_fusion/fixtures/resident_attention' / case),
        '--output', str(target), '--repetitions', '3']
    command = [str(BUILD / 'ci/run_black.sh'), 'hw', '--fpga-bin', ALIAS,
               '--app', 'llama_decoder_C4', '--args', ' '.join(app_args)]
    print(f'RUN {case}', flush=True)
    with (out / f'{case}.log').open('w') as log:
        subprocess.run(command, cwd=BUILD, stdout=log, stderr=subprocess.STDOUT,
                       timeout=900, check=True)
    verification = json.loads((target / 'verification.json').read_text())
    if verification.get('pass') is not True:
        raise RuntimeError(f'Correctness failed: {target}')
    operations = ['qk', 'softmax', 'pv'] if args.backend == 'legacy' else ['attention']
    with (target / 'profile.csv').open() as stream:
        rows = [row for row in csv.DictReader(stream) if row['operation'] in operations]
    for operation in operations:
        selected = [row for row in rows if row['operation'] == operation]
        if [int(row['repetition']) for row in selected] != [0, 1, 2]:
            raise RuntimeError(f'Missing {operation} samples: {target}')
    if args.backend != 'legacy':
        if len(rows) != 3:
            raise RuntimeError(f'Missing attention samples: {target}')
        for row in rows:
            if int(row['simd_cycles']) != sum(int(row[k + '_cycles']) for k in
                                            ['initialize', 'softmax', 'accumulate', 'finalize']):
                raise RuntimeError(f'Inconsistent phase counters: {target}')
    operation_medians = {
        operation: {k: statistics.median(int(row[k]) for row in rows if row['operation'] == operation)
                    for k in rows[0] if k not in ['operation', 'repetition', 'host_seconds']}
        for operation in operations
    }
    medians = operation_medians.get('attention', {
        'cycles': sum(operation_medians[operation]['cycles'] for operation in operations)})
    report[case] = {
        'verification': verification, 'samples': rows, 'median': medians,
        'backend': args.backend, 'operation_medians': operation_medians,
        'output_sha256': hashlib.sha256((target / 'output.bin').read_bytes()).hexdigest(),
        'kernel_sha256': hashlib.sha256((BUILD / 'tests/regression/llama_decoder_C4/kernel.elf').read_bytes()).hexdigest(),
        'command': command,
    }
    (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS {case}: {len(rows)} attention samples', flush=True)
print(out, flush=True)
