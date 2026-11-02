#!/usr/bin/env python3
"""Archive the measured 2x points and combine them with audited Fig. 5 results."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import shutil
import sys

TASK = Path(__file__).resolve().parent
BASE = TASK.parent / 'fpga-v2-resource-study/results'
sys.path.insert(0, str(TASK.parent / 'array-fpga-study'))
from resources import KEYS, add, hierarchy, sha


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def audit_report(directory):
    assert read(directory / 'status.json')['success'], directory
    summary = read(directory / 'summary.json')
    assert summary['blackboxes'] == 0 and summary['vivado'] == '2025.1'
    counts = hierarchy(directory / 'hierarchy.rpt')[0]['counts']
    text = (directory / 'utilization.rpt').read_text()
    assert 'Design State : Optimized' in text
    for key, label in {'LUT': 'CLB LUTs*', 'FF': 'CLB Registers', 'DSP': 'DSPs', 'URAM': 'URAM'}.items():
        match = re.search(r'^\|\s*' + re.escape(label) + r'\s*\|\s*([\d,.]+)', text, re.M)
        assert match and float(match[1].replace(',', '')) == counts[key], (directory, key)
    match = re.search(r'^\|\s*Block RAM Tile\s*\|\s*([\d,.]+)', text, re.M)
    assert match and float(match[1].replace(',', '')) == counts['RAMB36'] + counts['RAMB18'] / 2
    timing = (directory / 'timing_post_opt.rpt').read_text()
    for check in ('no_clock', 'unconstrained_internal_endpoints', 'loops'):
        assert f'checking {check} (0)' in timing, (directory, check)
    assert '-period 10.000' in (directory / 'clock.xdc').read_text()
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    parser.add_argument('--output', type=Path, default=TASK / 'results')
    args = parser.parse_args()
    build, out = args.build.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    archive = []
    def copy(src, relative):
        dest = out / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        archive.append(dict(file=str(relative), sha256=sha(dest), original=str(src)))

    # The archived measurements are immutable; current candidate configs have
    # evolved and are deliberately not used as evidence for this historical run.
    for entry in read(BASE / 'archive.json'):
        assert sha(BASE / entry['file']) == entry['sha256'], entry['file']
    rows = read(BASE / 'resources.json')
    for row in rows:
        assert audit_report(BASE / 'reports' / row['point']) == {k: row[k] for k in KEYS}
    manifest = read(build / 'fig5_fpga/manifest.json')
    assert manifest['git_commit'] == '1e4b367cca8f1a11cff74ce6b428079621b3a398'
    gate = read(build / 'axi_geometry_check/result.json')
    assert gate['status'] == 'pass' and gate['input_ports'] == 2 and gate['physical_ports'] == 32
    copy(build / 'axi_geometry_check/result.json', Path('verification/axi_geometry.json'))
    copy(build / 'axi_geometry_check/run.log', Path('verification/axi_geometry.log'))
    copy(build / 'fig5_fpga/manifest.json', Path('manifest.json'))

    for old, name in [('lmem_8', 'lmem_16'), ('cache_1', 'cache_2'), ('axi_1', 'axi_2')]:
        directory = build / 'fig5_fpga' / name
        counts = audit_report(directory)
        baseline = read(BASE / 'reports' / old / 'manifest.json')
        point = manifest['points'][name]
        params = dict(baseline['generics'])
        keys = ['NUM_REQS', 'NUM_BANKS'] if name.startswith('lmem') else ['NUM_REQS', 'NUM_BANKS', 'MEM_PORTS'] if name.startswith('cache') else ['NUM_PORTS_IN']
        for key in keys:
            params[key] *= 2
        assert point == dict(top=baseline['top'], parameters=params)
        src = build / 'fig5_fpga/sources' / point['top']
        sources = [Path(p) for p in (src / 'sources.txt').read_text().splitlines()]
        expected = {Path(p).name: h for p, h in baseline['sources'].items()}
        assert {p.name: sha(p) for p in sources} == expected
        for path in sources:
            copy(path, Path('sources') / point['top'] / path.name)
        for path in directory.iterdir():
            if path.is_file() and path.suffix in ('.rpt', '.csv', '.json', '.xdc', '.log'):
                copy(path, Path('reports') / name / path.name)
        rows.append(dict(point=name, **counts, BRAM36eq=counts['RAMB36'] + counts['RAMB18']/2,
                         MAC_per_cycle=0, reference_MHz=100, internal_ACC_KiB=0))

    by = {row['point']: row for row in rows}
    comparisons = {}
    for factor in (2, 4):
        data = []
        for engine, memory in [('fp_tcu_128', ['lmem_8', 'cache_1', 'axi_1']),
                               ('wkv_16x16', [f'lmem_{8*factor}', f'cache_{factor}', f'axi_{factor}'])]:
            for with_memory in (False, True):
                names = memory if with_memory else []
                counts = add([by[engine], *(by[n] for n in names)])
                gops = by[engine]['nominal_GOPS']
                data.append(dict(engine=engine, scope='engine + memory subsystem' if with_memory else 'engine only',
                                 memory_points=names, **counts, BRAM36eq=counts['RAMB36']+counts['RAMB18']/2,
                                 nominal_GOPS=gops, GOPS_per_kLUT=gops*1000/counts['LUT'], GOPS_per_DSP=gops/counts['DSP']))
        if factor == 4:
            assert data == read(BASE / 'comparison.json'), '4x reference must remain identical'
        comparisons[str(factor)] = data
        save(out / f'comparison_{factor}x.json', data)
    save(out / 'resources.json', rows)
    with (out / 'resources.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(dict.fromkeys(k for row in rows for k in row)))
        writer.writeheader()
        writer.writerows(rows)
    interpretation = {factor: dict(engine_only=data[2]['GOPS_per_kLUT']/data[0]['GOPS_per_kLUT'],
                                   with_memory=data[3]['GOPS_per_kLUT']/data[1]['GOPS_per_kLUT'])
                      for factor, data in comparisons.items()}
    assert math.isclose(interpretation['4']['with_memory'], 0.6323490556583059)
    save(out / 'interpretation.json', interpretation)
    baseline_harness = read(BASE / 'provenance/harness.json')
    harness = {}
    for name in ('run.py', 'synth.tcl', 'report.tcl'):
        path = Path('agent-tasks/fig5-fpga') / name
        harness[str(path)] = sha(TASK.parents[1] / path)
        assert harness[str(path)] == baseline_harness[str(path)]
    for path in TASK.glob('*.py'):
        harness[str(path.relative_to(TASK.parents[1]))] = sha(path)
    save(out / 'harness.json', harness)
    save(out / 'archive.json', archive)
    save(out / 'audit.json', dict(status='pass', archived_reports=9, new_reports=3,
         exact_preprocessed_source_match=True, unchanged_4x_comparison=True,
         baseline_archive_sha256=sha(BASE / 'archive.json'),
         support_hashes=read(BASE / 'provenance/rtl_support.json'),
         checkpoint_hashes={name: sha(build / 'fig5_fpga' / name / 'post_opt.dcp') for name in ('lmem_16','cache_2','axi_2')},
         scope='Separately synthesized memory costs added to archived engines; nominal 100 MHz, not measured throughput or routed timing. Physical HBM ports remain 32.'))
    print(json.dumps(interpretation, indent=2))


if __name__ == '__main__':
    main()
