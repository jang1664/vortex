#!/usr/bin/env python3
"""Check the portable saved resource dataset against its Vivado reports."""
import argparse
import csv
import hashlib
import json
import math
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('results', type=Path)
args = parser.parse_args()
root = args.results
read = lambda name: json.loads((root/name).read_text())
audit = read('audit.json')
memory = read('memory_resources.json')
comparison = read('comparison.json')
assert len(audit['points']) == 8 and len(memory) == 6 and len(comparison) == 4
assert len({p['point'] for p in audit['points']}) == 8
assert read('memory_manifest.json')['git_commit'] == audit['git_commit']

labels = {'LUT': 'CLB LUTs*', 'FF': 'CLB Registers', 'DSP': 'DSPs',
          'BRAM_tiles': 'Block RAM Tile'}
reported = {}
for item in audit['points']:
    point = item['point']
    path = root/'reports'/point
    raw = (path/'utilization.rpt').read_bytes()
    assert hashlib.sha256(raw).hexdigest() == item['utilization_sha256'], point
    text = raw.decode()
    assert 'Design State : Optimized' in text, point
    status = json.loads((path/'status.json').read_text())
    summary = json.loads((path/'summary.json').read_text())
    assert status['success'] and status['exit_code'] == 0, point
    assert summary['blackboxes'] == item['blackboxes'] == 0, point
    assert item['clock_mhz'] == 100 and item['unclocked_pins'] == 0, point
    reported[point] = {}
    for key, label in labels.items():
        match = re.search(r'^\|\s*'+re.escape(label)+r'\s*\|\s*([\d,.]+)', text, re.M)
        assert match, (point, label)
        reported[point][key] = float(match[1].replace(',', ''))

mem = {row['point']: row for row in memory}
engines = {row['point']: row for row in comparison if row['scope'] == 'engine only'}
for row in [*memory, *engines.values()]:
    for key, value in reported[row['point']].items():
        assert row[key] == value, (row['point'], key, row[key], value)
for row in comparison:
    engine = engines[row['point']]
    names = (['lmem_16', 'cache_2', 'axi_2'] if row['point'] == 'tcu_fp16'
             else ['lmem_64', 'cache_8', 'axi_8'])
    for key in ['LUT', 'FF', 'DSP', 'BRAM_tiles', 'URAM']:
        expected = engine[key]
        if row['scope'] != 'engine only':
            expected += sum(mem[name][key] for name in names)
        assert row[key] == expected, (row['point'], row['scope'], key)
    gops = row['MAC_per_cycle'] * 2 * 0.1
    assert math.isclose(row['nominal_GOPS_at_100MHz'], gops)
    assert math.isclose(row['nominal_GOPS_per_kLUT'], gops/(row['LUT']/1000))
    assert math.isclose(row['nominal_GOPS_per_DSP'], gops/row['DSP'])
for filename, rows in [('memory_resources.csv', memory), ('comparison.csv', comparison)]:
    with (root/filename).open() as f:
        actual = list(csv.DictReader(f))
    assert actual == [{key: str(value) for key, value in row.items()} for row in rows], filename
notes = read('interpretation.json')
for i, key in enumerate(['engine_only_relative_GOPS_per_kLUT', 'with_memory_relative_GOPS_per_kLUT']):
    ratio = comparison[2+i]['nominal_GOPS_per_kLUT']/comparison[i]['nominal_GOPS_per_kLUT']
    assert math.isclose(notes[key], ratio), key
print('PASS: 8 report hashes/statuses, resource counts, CSV/JSON, additive costs and efficiency ratios')
