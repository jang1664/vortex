#!/usr/bin/env python3
"""Verify the paired figures' archived evidence without Vivado/build products."""
import argparse
import csv
import math
from pathlib import Path
from collect import BASE, TASK, KEYS, add, audit_report, read, sha

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('results', type=Path, nargs='?', default=TASK / 'results')
out = parser.parse_args().results
for directory in (BASE, out):
    for entry in read(directory / 'archive.json'):
        assert sha(directory / entry['file']) == entry['sha256'], entry['file']
audit = read(out / 'audit.json')
assert audit['status'] == 'pass'
for path, expected in read(out / 'harness.json').items():
    assert sha(TASK.parents[1] / path) == expected, path
assert sha(BASE / 'archive.json') == audit['baseline_archive_sha256']
rows = read(out / 'resources.json')
by = {row['point']: row for row in rows}
assert len(by) == len(rows) == 12
for row in rows:
    parent = out if row['point'] in ('lmem_16', 'cache_2', 'axi_2') else BASE
    assert audit_report(parent / 'reports' / row['point']) == {k: row[k] for k in KEYS}
for old in ('lmem_8', 'cache_1', 'axi_1'):
    manifest = read(BASE / 'reports' / old / 'manifest.json')
    expected = {Path(p).name: h for p, h in manifest['sources'].items()}
    actual = {p.name: sha(p) for p in (out / 'sources' / manifest['top']).iterdir()}
    assert actual == expected
for factor in (2, 4):
    data = read(out / f'comparison_{factor}x.json')
    assert len(data) == 4
    for i, row in enumerate(data):
        engine = 'fp_tcu_128' if i < 2 else 'wkv_16x16'
        multiplier = 1 if i < 2 else factor
        memory = [f'lmem_{8*multiplier}', f'cache_{multiplier}', f'axi_{multiplier}'] if i % 2 else []
        assert row['engine'] == engine and row['memory_points'] == memory
        counts = add([by[engine], *(by[n] for n in memory)])
        assert counts == {k: row[k] for k in KEYS}
        assert row['nominal_GOPS'] == (25.6 if i < 2 else 51.2)
        assert math.isclose(row['GOPS_per_kLUT'], row['nominal_GOPS'] * 1000 / counts['LUT'])
    for i, scope in enumerate(('engine_only', 'with_memory')):
        assert math.isclose(read(out / 'interpretation.json')[str(factor)][scope],
                            data[2+i]['GOPS_per_kLUT'] / data[i]['GOPS_per_kLUT'])
    if factor == 4:
        assert data == read(BASE / 'comparison.json')
with (out / 'resources.csv').open() as stream:
    csvrows = list(csv.DictReader(stream))
    assert len(csvrows) == len(rows)
    for actual, expected in zip(csvrows, rows):
        assert all(actual[k] == str(v) for k, v in expected.items())
print('PASS: 12 measured reports, archived hashes, identical RTL, resource arithmetic, CSV, and unchanged 4x reference')
