"""Bounded M4 Weight gather requests: byte address, bank and lane handshake."""
from pathlib import Path
import csv,json,re,sys
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1];sys.path.insert(0,str(ROOT/'tools'));import fsdb_cli
run=TASK/'runs/v2/p32_b32/m4';out=TASK/'captures/v2/p32_b32/m4';core='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core';base=core+'/gemm_node_naive/weight_executor/gather'
c=np.arange(9100,9320);times=c*10000+5000;s={}
for lane in range(4):
 for key,path in [('addr',f'g_lane[{lane}]/lane_byte_addr'),('valid',f'lmem_bus_if[{lane}]/req_valid'),('ready',f'lmem_bus_if[{lane}]/req_ready')]:
  p=out/f'weight_lane{lane}_{key}.json'
  if not p.exists():
   r=fsdb_cli.report(str(run/'wave.fsdb'),[base+'/'+path],bt='90000000ps',et='94000000ps');assert r.data_rows,path;p.write_text(json.dumps(r.data_rows))
  rows=json.loads(p.read_text());t=np.array([int(r[0]) for r in rows]);v=np.array([int(re.sub('[xXzZ]','0',r[1]),2) for r in rows]);idx=np.searchsorted(t,times,side='left')-1;assert (idx>=0).all();s[f'{lane}_{key}']=v[idx]
rows=[]
for i,cycle in enumerate(c):
 for lane in range(4):
  if s[f'{lane}_valid'][i]:
   addr=int(s[f'{lane}_addr'][i]);rows.append(dict(cycle=int(cycle),lane=lane,byte_addr=hex(addr),word_addr=addr//8,bank16=(addr//8)%16,bank32=(addr//8)%32,ready=int(s[f'{lane}_ready'][i])))
with (TASK/'m4-weight-window.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
print(json.dumps(rows[:32],indent=2))
