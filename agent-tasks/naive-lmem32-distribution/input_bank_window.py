"""Bounded current-M256 Input address and physical bank-service evidence."""
from pathlib import Path
import csv,json,re,sys
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
sys.path.insert(0,str(ROOT/'tools'));import fsdb_cli
RUN=TASK/'runs/v2/p32_b32/m256'
r=json.loads((RUN/'result.json').read_text());assert r['passed']
meta=dict(re.findall(r'(\w+)=([^\s]+)',r['observer_done'][0]));start=int(meta['e_cfg'])+10000;end=start+512
C='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core';N=C+'/gemm_node_naive';L=C+'/mem_unit/local_mem'
p={k:L+'/'+v for k,v in {'bank_valid':'per_bank_req_valid','bank_ready':'per_bank_req_ready','bank_rw':'per_bank_req_rw','bank_ports':'per_bank_req_idx'}.items()}
for lane in range(4):
 for k,sig in [('valid','req_valid'),('ready','req_ready'),('addr','req_data.addr')]:p[f'i{lane}_{k}']=N+f'/i_lane_mem_if[{lane}]/'+sig
for k,bus in [('pr','psum_rd_raw_bus_if'),('pw','psum_wr_raw_bus_if')]:
 for a,sig in [('valid','req_valid'),('ready','req_ready'),('addr','req_data.addr')]:p[k+'_'+a]=N+'/'+bus+'/'+sig
p['input_fire']=N+'/u_VX_gemm_compute_core/input_fire'
rep=fsdb_cli.report(str(RUN/'wave.fsdb'),list(p.values()),bt=f'{(start-1)*10}ns',et=f'{end*10}ns');assert rep.time_unit=='1ps'
ev=rep.events();widths={k:len(ev[0].values[n]) for k,n in zip(p,rep.signal_names)};times=np.array([e.time for e in ev]);rows=[]
for c in range(start,end):
 e=ev[np.searchsorted(times,c*10000+5000,side='left')-1];row={'cycle':c}
 for k,s in zip(p,rep.signal_names):
  raw=e.values[s];row[k]=int(re.sub('[xXzZ]','0',raw),2)
  if k in ['bank_ready','bank_rw','bank_ports'] or k.endswith('addr'):row[k+'_known']=int(''.join('1' if b in '01' else '0' for b in raw),2)
  elif k.endswith('addr'):pass
  else:assert re.fullmatch('[01]+',raw),(c,k,raw)
 for prefix in ['i0','i1','i2','i3','pr','pw']:
  if row[prefix+'_valid'] and row[prefix+'_ready']:
   assert row[prefix+'_addr_known']==(1<<widths[prefix+'_addr'])-1
 rows.append(row)
with (TASK/'m256-input-bank-window.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
banks=[dict(bank=b,service=0,psum_read=0,psum_write_or_final=0,other=0) for b in range(32)]
for row in rows:
 v=row['bank_valid'];assert v & ~row['bank_ready_known']==0
 fire=v&row['bank_ready'];assert fire & ~row['bank_rw_known']==0
 for b in range(32):
  if fire>>b&1:
   assert (row['bank_ports_known']>>(b*5))&31==31
   port=(row['bank_ports']>>(b*5))&31;banks[b]['service']+=1
   # Physical ranges alone are not request-type attribution: ordinary DMA
   # also shares these ports. Label this evidence as port-range counts.
   cls='psum_read' if port<8 else 'psum_write_or_final' if port<16 else 'other'
   banks[b][cls]+=1
summary={'window':[start,end],'cycles':len(rows),'paths':p,'bank_service_by_port_range':banks,'input_lanes':[],'input_fire':sum(x['input_fire'] for x in rows),'classification_note':'Bank categories are physical port ranges, not tag-decoded ownership; CPU/DMA can share those ports.'}
for lane in range(4):
 req=[x for x in rows if x[f'i{lane}_valid'] and x[f'i{lane}_ready']]
 summary['input_lanes'].append({'lane':lane,'requests':len(req),'banks':sorted({x[f'i{lane}_addr']%32 for x in req}),'first_requests':[{'cycle':x['cycle'],'word_addr':x[f'i{lane}_addr'],'bank':x[f'i{lane}_addr']%32} for x in req[:8]]})
for k in ['pr','pw']:
 req=[x for x in rows if x[k+'_valid'] and x[k+'_ready']]
 summary[k]={'requests':len(req),'first_requests':[{'cycle':x['cycle'],'wide_addr':x[k+'_addr'],'first_bank':x[k+'_addr']*8%32} for x in req[:8]]}
(TASK/'m256-input-bank-window.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
