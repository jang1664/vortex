"""Aggregate retained matched depth sweeps and the fixed-latency unit benchmark."""
from pathlib import Path
import csv
import json
import re
root = Path(__file__).resolve().parent
rows = []
for p in sorted(root.glob('depth[0-9]*/results.json'), key=lambda p:int(p.parent.name[5:])):
    for r in json.loads(p.read_text()):
        stats = r['depth_stats']
        rows.append(dict(depth=r['write_depth'], case=r['case'], passed=r['passed'], cycles=r['cycles'],
          change_vs_depth16_pct=(r['cycles']/291410-1)*100 if r['case']=='inorder' and r['cycles'] else '',
          max_occupancy=max((x['max_occupancy'] for x in stats),default=0),
          full_port_cycles=sum(x['full_cycles'] for x in stats),
          unavailable_port_cycles=sum(x['slot_unavailable_cycles'] for x in stats),
          scan_slots=sum(x['scan_requests'] for x in stats),
          read_blocked_port_cycles=sum(x['read_blocked_cycles'] for x in stats),
          addrw=next((x['addrw'] for x in stats if 'addrw' in x), ''),
          idw=next((x['idw'] for x in stats if 'idw' in x), ''),
          kernel_sha256=r['kernel_sha256']))
if rows:
    with (root/'softmax.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
bench=[]
for line in (root/'bench_boundary.log').open():
    if 'WRITE_DEPTH_BENCH ' in line:
        row={k:int(v) for k,v in re.findall(r'(\w+)=([0-9]+)',line)}
        row['writes_per_cycle']=row['window_aw']/row['window_cycles']
        bench.append(row)
bench.sort(key=lambda r:r['depth'])
with (root/'write_pressure.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(bench[0]));w.writeheader();w.writerows(bench)
for r in rows:
    print({k:r[k] for k in ['depth','case','cycles','change_vs_depth16_pct','max_occupancy','full_port_cycles','scan_slots','read_blocked_port_cycles','addrw','idw']})
