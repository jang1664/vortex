#!/usr/bin/env python3
"""Combine separately synthesized engine and memory costs, never integrated P&R."""
import csv
import json
from pathlib import Path
import sys

build=Path(sys.argv[1]).resolve()
memroot=build/'fig5_fpga'
root=build/'fig5_fpga_compute'
mem={r['point']:r for r in json.loads((memroot/'resources.json').read_text())}
assert len(mem)==6
engines=[]
for point in ['tcu_fp16','fpint_32x32']:
    p=root/point
    assert (p/'post_opt.dcp').exists() and json.loads((p/'status.json').read_text())['success']
    header=None
    for line in (p/'hierarchy.rpt').read_text().splitlines():
        if not line.startswith('|'): continue
        fields=[s.strip() for s in line.split('|')[1:-1]]
        if not fields: continue
        if fields[0]=='Instance': header=fields; continue
        if not header or len(fields)!=len(header): continue
        try: vals={k:int(v.replace(',','')) for k,v in zip(header[2:],fields[2:])}
        except ValueError: continue
        manifest=json.loads((p/'manifest.json').read_text())
        engines.append(dict(point=point,LUT=vals['Total LUTs'],FF=vals['FFs'],
            DSP=vals['DSP Blocks'],BRAM_tiles=vals['RAMB36']+vals['RAMB18']/2,URAM=vals['URAM'],
            MAC_per_cycle=manifest['macs_per_cycle']))
        break
rows=[]
for e, names in zip(engines,[['lmem_16','cache_2','axi_2'],['lmem_64','cache_8','axi_8']]):
    for include in [False,True]:
        row=dict(e,scope='engine + memory subsystem' if include else 'engine only')
        for key in ['LUT','FF','DSP','BRAM_tiles','URAM']:
            row[key]+=sum(mem[n][key] for n in names) if include else 0
        row['nominal_GOPS_at_100MHz']=e['MAC_per_cycle']*2*.1
        row['nominal_GOPS_per_kLUT']=row['nominal_GOPS_at_100MHz']/(row['LUT']/1000)
        row['nominal_GOPS_per_DSP']=row['nominal_GOPS_at_100MHz']/row['DSP'] if row['DSP'] else None
        rows.append(row)
with (root/'comparison.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=rows[0], lineterminator="\n");w.writeheader();w.writerows(rows)
(root/'comparison.json').write_text(json.dumps(rows,indent=2))
ratios=[rows[2+i]['nominal_GOPS_per_kLUT']/rows[i]['nominal_GOPS_per_kLUT'] for i in [0,1]]
notes={
 'engine_only_relative_GOPS_per_kLUT':ratios[0],
 'with_memory_relative_GOPS_per_kLUT':ratios[1],
 'relative_efficiency_retained':ratios[1]/ratios[0],
 'measurement':'Vivado 2025.1, U55C, OOC synthesis + existing async-RAM patch + opt_design',
 'frequency':'100 MHz is a common reference for nominal throughput; no post-route Fmax/closure claim',
 'integration':'Independent block cost sum, not a connected system or deployed C1/C4 measurement',
 'memory':'512 KiB LMEM + 4 MiB cache fixed; BRAM storage reported separately; GEMM has additional 256 KiB internal ACC',
 'topology':'LMEM full crossbar; cache retains current mixed crossbar/Omega; AXI output bank count fixed at 32',
 'baseline':'Actual 8 x 4 x (2 x 4) FP16 TCU = 256 MAC/cycle, not an analytic 16x16 array',
 'resource_caution':'GOPS/kLUT does not price DSP/BRAM cost; report all resources alongside it',
 'scope':'GEMM unit including prealignment, scaling, accumulation and local control; no full SIMT core, host shell or system DMA',
}
(root/'interpretation.json').write_text(json.dumps(notes,indent=2))
print(json.dumps({'rows':rows,'interpretation':notes},indent=2))
from plot import plot_comparison
plot_comparison(list(mem.values()), rows, root)
