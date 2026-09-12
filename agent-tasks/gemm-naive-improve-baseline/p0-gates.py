#!/usr/bin/env python3
"""Derive numeric acceptance thresholds from verified corrected captures."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex

TASK = Path(__file__).resolve().parent


def measured(run, backend, m):
    manifest = json.loads((run / 'manifest.json').read_text())
    assert manifest['backend'] == backend
    assert (manifest['m'], manifest['k'], manifest['n'], manifest['repeat']) == (m, 512, 512, 1)
    command = manifest['command']
    argv = shlex.split(command[command.index('--args') + 1])
    assert argv == ['-m', str(m), '-k', '512', '-n', '512', '-q', '32', '-t', '0', '-d', '0', '-r', '1']
    assert manifest['passed'] and manifest['returncode'] == 0
    assert not manifest['source_changes_during_run']
    defines = shlex.split(manifest['configs'])
    for define in ('-DNUM_THREADS=16', '-DMXU_ROW=16', '-DMXU_COL=16', '-DGEMM_LATENCY_OBSERVER'):
        assert define in defines
    endpoint = json.loads((run / 'endpoints/latency.json').read_text())
    assert endpoint['log_match'] is True and not endpoint['differences']
    assert len(endpoint['jobs']) == 1
    assert Path(endpoint['wave']).resolve() == (run / 'wave.fsdb').resolve()
    cores = re.findall(r'^PERF: instrs=\d+, cycles=(\d+),',
                       (run / 'wrapper.log').read_text(), re.M)
    assert len(cores) == 1
    return dict(gemm_cycles=endpoint['jobs'][0]['L_gemm'], core_cycles=int(cores[0]),
                run=str(run.resolve()),
                oracle_sha256=manifest['source_hashes']['tests/regression/fpint_gemm_ffn_hw/test_vectors.h'],
                manifest_sha256=hashlib.sha256((run / 'manifest.json').read_bytes()).hexdigest(),
                endpoints_sha256=hashlib.sha256((run / 'endpoints/latency.json').read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--naive-m256', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    captures = {}
    for backend in ('naive', 'improve'):
        for m in (4, 256):
            run = args.naive_m256 if (backend, m) == ('naive', 256) else TASK / 'p0-baseline' / f'{backend}-m{m}{"-retry1" if m == 4 else ""}'
            captures[f'{backend}_m{m}'] = measured(run, backend, m)
    assert len({capture['oracle_sha256'] for capture in captures.values()}) == 1
    gates = {}
    for name, capture in captures.items():
        if name.startswith('improve'):
            gates[name] = dict(gemm_cycles_equal=capture['gemm_cycles'], core_cycles_equal=capture['core_cycles'])
        else:
            numerator, denominator = (3, 4) if name.endswith('m4') else (101, 100)
            gates[name] = dict(gemm_cycles_max=capture['gemm_cycles'] * numerator // denominator,
                               core_cycles_max=capture['core_cycles'] * 101 // 100)
    service = json.loads((TASK / 'p0-service-naive-m4-results.json').read_text())
    assert service['status'] == 'pass'
    window = service['window']
    assert (window['first_ordinal'], window['last_ordinal'], window['eligible_pairs'],
            window['accepted_input_rows']) == (256, 767, 510, 2048)
    assert window['excluded_pairs'] == [[511, 512]]
    gates['naive_m4_service'] = dict(first_ordinal=256, last_ordinal=767,
        accepted_input_rows=2048, eligible_pairs=510, overlapping_pairs_min=255,
        interval_cycles_max=window['interval_cycles'] * 4 // 5,
        baseline_interval_cycles=window['interval_cycles'])
    cost = json.loads((TASK / 'p0-baseline/improve-cost/summary.json').read_text())
    gates['improve_cost_equal'] = cost['top']
    result = dict(status='numeric_thresholds_derived', baseline_frozen=False,
                  note='Numeric gates only. Full P0 exit additionally requires the storage, ownership, oracle, lifecycle, and structural evidence; this script cannot declare P0 or the redesign complete.',
                  captures=captures, gates=gates, improve_cost_provenance=cost)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(gates, indent=2))


if __name__ == '__main__':
    main()
