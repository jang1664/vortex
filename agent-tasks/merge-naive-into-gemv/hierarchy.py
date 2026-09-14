#!/usr/bin/env python3
"""Inspect the exact VCS blackbox executables without advancing simulation time."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import re
import subprocess
import sys
from verify import BASE, ROOT, EXEC

OUT = EXEC / 'hierarchy'
OUT.mkdir(exist_ok=True)
SCRIPT = '''
set all [search -instances -scope tb_vcs_xrtsim -limit 1000000 *]
set fd [open instances.txt w]
puts $fd $all
close $fd
foreach module {VX_mem_bus_split VX_mem_bus_split_reorder VX_dma_node VX_naive_dma_slr} {
    set matches [search -instances -scope tb_vcs_xrtsim -module $module -limit 1000000 *]
    set fd [open $module.txt w]
    puts $fd $matches
    close $fd
}
quit
'''


def inspect(item):
    revision, mode = item
    label = revision + '_improve_' + mode
    source = BASE if revision == 'baseline' else ROOT
    simv = source / ('build_merge_' + label) / 'sim/xrtsim_vcs/simv'
    out = OUT / label
    out.mkdir(exist_ok=False)
    (out / 'inspect.tcl').write_text(SCRIPT)
    command = [str(simv), '-ucli', '-do', 'inspect.tcl']
    with (out / 'inspect.log').open('w') as log:
        subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT,
                       timeout=120, check=True)
    instances = (out / 'instances.txt').read_text().strip().splitlines()
    absent = {module: not (out / (module + '.txt')).read_text().strip()
              for module in ['VX_mem_bus_split', 'VX_mem_bus_split_reorder',
                             'VX_dma_node', 'VX_naive_dma_slr']}
    assert len(instances) > 100, 'Empty hierarchy is not evidence'
    return dict(label=label, instance_lines=len(instances), absent=absent,
                instances_sha256=hashlib.sha256('\n'.join(sorted(instances)).encode()).hexdigest(),
                simv_sha256=hashlib.sha256(simv.read_bytes()).hexdigest(), command=command)


def normalize(label):
    lines = (OUT / label / 'instances.txt').read_text().strip().splitlines()
    # These names are generated from __LINE__; the preprocessor comparison
    # independently proves their bodies/references identical. Number them per
    # enclosing scope and macro kind, preserving distinct instances.
    pattern = r'([\w.\[\]$]+)\.__(buffer_ex|pop_count_ex)(\d+)'
    groups = {}
    for line in lines:
        for parent, kind, number in re.findall(pattern, line):
            groups.setdefault((parent, kind), set()).add(int(number))
    mapping = {(parent, kind, number): i for (parent, kind), numbers in groups.items()
               for i, number in enumerate(sorted(numbers))}
    def rename(m):
        parent, kind, number = m.groups()
        return f'{parent}.__{kind}CANON{mapping[parent, kind, int(number)]}'
    canonical = sorted(re.sub(pattern, rename, line) for line in lines)
    assert len(set(canonical)) == len(set(lines)), 'Normalization collapsed distinct instances'
    (OUT / label / 'canonical_instances.txt').write_text('\n'.join(canonical) + '\n')
    return hashlib.sha256('\n'.join(canonical).encode()).hexdigest()


if __name__ == '__main__':
    if '--summarize' in sys.argv:
        records = json.loads((OUT / 'result.json').read_text())['records']
    else:
        with ThreadPoolExecutor(max_workers=2) as pool:
            records = list(pool.map(inspect, [(revision, mode) for revision in ['baseline', 'candidate']
                                             for mode in ['off', 'on']]))
    for record in records:
        record.setdefault('raw_instances_sha256', record['instances_sha256'])
        record['instances_sha256'] = normalize(record['label'])
    matches = {mode: records[i]['instances_sha256'] == records[i+2]['instances_sha256']
               for i, mode in enumerate(['off', 'on'])}
    result = dict(passed=all(matches.values()) and all(all(r['absent'].values()) for r in records),
                  hierarchy_identical=matches, records=records)
    (OUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if result['passed'] else 1)
