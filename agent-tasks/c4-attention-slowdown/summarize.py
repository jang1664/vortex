#!/usr/bin/env python3
"""Retain small, auditable cycle samples; large hardware logs stay ignored."""
import csv
import hashlib
import json
from pathlib import Path
import statistics

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
report = {'baseline_commit': 'f0305e136402f6ee52a4a829be78a28ae7302cee',
          'clock_mhz': 100, 'variants': {}}
for variant in sorted((TASK / 'runs').iterdir()):
    if not variant.is_dir():
        continue
    cases = {}
    for profile in sorted(variant.glob('*/profile.csv')):
        rows = [row for row in csv.DictReader(profile.open()) if row['operation'] == 'attention']
        if len(rows) != 3:
            raise ValueError(f'Expected three attention samples: {profile}')
        for row in rows:
            assert int(row['simd_cycles']) == sum(int(row[k + '_cycles']) for k in
                                                 ['initialize', 'softmax', 'accumulate', 'finalize'])
        medians = {k: statistics.median(int(row[k]) for row in rows)
                   for k in rows[0] if k not in ['operation', 'repetition', 'host_seconds']}
        cases[profile.parent.name] = {
            'median_cycles': medians,
            'samples': rows,
            'verification': json.loads((profile.parent / 'verification.json').read_text()),
            'output_sha256': hashlib.sha256((profile.parent / 'output.bin').read_bytes()).hexdigest(),
            'context_sha256': hashlib.sha256((profile.parent / 'context.bin').read_bytes()).hexdigest(),
            'matches_instrumented_baseline': {
                name: (profile.parent / name).read_bytes() ==
                      (TASK / 'runs/instrumented' / profile.parent.name / name).read_bytes()
                for name in ['q_hadamard.bin', 'context.bin', 'output.bin']
            },
            'evidence': str(profile.relative_to(ROOT)),
        }
    report['variants'][variant.name] = cases
report['failed_experiment'] = {
    'variant': 'word_padding', 'slurm_job': 5985,
    'result': 'Stalled at attention for >120 seconds; canceled, exit 143. No valid timing or correctness result.',
    'adopted': False,
}
(TASK / 'measurements.json').write_text(json.dumps(report, indent=2) + '\n')
for variant, cases in report['variants'].items():
    for name, result in cases.items():
        print(variant, name, result['median_cycles']['cycles'], result['verification']['pass'])
