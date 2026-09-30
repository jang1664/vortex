#!/usr/bin/env python3
"""Extract validated post-opt resource totals and nonoverlapping hierarchy rows."""
import csv
import json
import re
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
rows = []
hierarchy = []
for point in ('lmem_16', 'lmem_64', 'cache_2', 'cache_8', 'axi_2', 'axi_8'):
    path = root / point
    if not ((path / 'summary.json').exists() and (path / 'post_opt.dcp').exists()
            and (path / 'status.json').exists()
            and json.loads((path / 'status.json').read_text())['success']):
        print(f'Pending: {point}')
        continue
    header = None
    top_seen = False
    for line in (path / 'hierarchy.rpt').read_text().splitlines():
        if not line.startswith('|'):
            continue
        fields = [v.strip() for v in line.split('|')[1:-1]]
        if not fields:
            continue
        if fields[0] == 'Instance':
            header = fields
            continue
        if not header or len(fields) != len(header):
            continue
        try:
            vals = {k: int(v.replace(',', '')) for k, v in zip(header[2:], fields[2:])}
        except ValueError:
            continue
        rec = dict(point=point, instance=fields[0], module=fields[1], **vals)
        # Retain indentation to reconstruct hierarchy without double counting.
        raw = line.split('|')[1]
        rec['indent'] = len(raw)-len(raw.lstrip())
        hierarchy.append(rec)
        if not top_seen:
            rows.append(dict(point=point, LUT=vals['Total LUTs'], logic_LUT=vals['Logic LUTs'],
                LUTRAM=vals['LUTRAMs'], SRL=vals['SRLs'], FF=vals['FFs'],
                BRAM36=vals['RAMB36'], BRAM18=vals['RAMB18'],
                BRAM_tiles=vals['RAMB36']+vals['RAMB18']/2,
                URAM=vals['URAM'], DSP=vals['DSP Blocks']))
            top_seen = True
if rows:
    with (root / 'resources.csv').open('w') as f:
        w=csv.DictWriter(f, fieldnames=rows[0], lineterminator="\n"); w.writeheader(); w.writerows(rows)
    (root / 'resources.json').write_text(json.dumps(rows, indent=2))
    (root / 'hierarchy.json').write_text(json.dumps(hierarchy, indent=2))
    for row in rows:
        print(json.dumps(row))
# Classify non-overlapping primitive-bearing hierarchy roots. Parent rows
# include descendants, so descendants of an already selected scope are skipped.
breakdown=[]
for row in rows:
    groups={'fabric': [], 'storage': []}
    stack=[]
    selected=[]
    for h in [h for h in hierarchy if h['point']==row['point']]:
        if h['instance'].startswith('('):
            continue
        while stack and stack[-1][0] >= h['indent']:
            stack.pop()
        path='/'.join([v[1] for v in stack]+[h['instance']])
        stack.append((h['indent'],h['instance']))
        if any(path.startswith(p+'/') for p in selected):
            continue
        category = ('fabric' if re.match(r'VX_(?:stream_(?:xbar|omega|arb|switch)|mem_(?:arb|switch))(?:_|$)',h['module'])
                    else 'storage' if re.match(r'VX_(?:sp|dp)_ram(?:_|$)',h['module']) else None)
        if category:
            groups[category].append(dict(path=path, **h))
            selected.append(path)
    sums={cat:sum(h['Total LUTs'] for h in vals) for cat,vals in groups.items()}
    residual=row['LUT']-sum(sums.values())
    assert residual >= 0, (row,sums)
    breakdown.append(dict(point=row['point'],total_LUT=row['LUT'],fabric_LUT=sums['fabric'],
                          storage_wrapper_LUT=sums['storage'],other_control_LUT=residual,scopes=groups))
(root/'breakdown.json').write_text(json.dumps(breakdown,indent=2))

if len(rows) == 6:
    from plot import plot_memory
    plot_memory(rows, root)
