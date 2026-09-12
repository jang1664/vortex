"""Reconstruct physically pending PSUM writes and classify blocked reads."""
import argparse,json,sys
from collections import Counter
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
ap=argparse.ArgumentParser();ap.add_argument('--m',type=int,required=True);args=ap.parse_args()
case=f'naive32-m{args.m}';old=TASK/'captures'/case;d=json.loads((old/'result.json').read_text());cfg=d['boundaries']['cfg'];end=d['boundaries']['done'];cycles=np.arange(cfg,end);times=cycles*10000+5000
out=TASK/'captures'/f'{case}-read-priority';out.mkdir(exist_ok=True)
core='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core';node=core+'/gemm_node_naive'
paths={'rd_valid':node+'/psum_rd_raw_bus_if/req_valid','rd_addr':node+'/psum_rd_raw_bus_if/req_data.addr','wr_valid':node+'/psum_wr_raw_bus_if/req_valid','wr_ready':node+'/psum_wr_raw_bus_if/req_ready','wr_addr':node+'/psum_wr_raw_bus_if/req_data.addr','reserve':node+'/psum_wr_reserve','commits':node+'/naive_write_commit','bank_addr':core+'/mem_unit/local_mem/per_bank_req_addr','pending0':node+'/psum_wr_pending_by_set[0]','pending1':node+'/psum_wr_pending_by_set[1]'}
a={}
for name,path in paths.items():
 cache=out/(name+'.npz')
 if cache.exists():z=np.load(cache);t=z['t'];v=z['v']
 else:
  r=fsdb_cli.report(str(ROOT/d['run']/'wave.fsdb'),[path],bt=f'{cfg*10}ns',et=f'{end*10+10}ns');assert r.data_rows and r.time_unit=='1ps',path
  t=np.array([int(row[0]) for row in r.data_rows]);v=np.array([row[1] for row in r.data_rows]);np.savez_compressed(cache,t=t,v=v)
 idx=np.searchsorted(t,times,side='left')-1;assert np.all(idx>=0)
 if name=='bank_addr':a[name]=v[idx]
 else:
  vs=v[idx];assert all(x and set(x)<=set('01') for x in vs),name
  a[name]=np.array([int(x,2) for x in vs],dtype=np.int64)
 print('loaded',name,flush=True)
for name in ['psum_rd_order_block','psum_rd_pending_conflict','psum_rd_current_conflict','dma_busy','post_txn_count','post_head_psum_ready','post_head_scaled_ready','acc_result_credit','acc_result_commit']:
 z=np.load(old/(name+'.npz'));a[name]=z['v'][np.searchsorted(z['t'],times,side='left')-1]
# Eight 8-byte lanes per 64-byte PSUM row; sixteen banks, 1MiB LMEM.
LANES=8;BANKS=16;BANK_ADDR_BITS=13;ROW_MASK=(1<<14)-1
pending=Counter();stats=Counter({k:0 for k in ['same_row_pending','same_row_current_only','different_rows_only']});examples={};detail=[]
for j,c in enumerate(cycles):
 rd=int(a['rd_addr'][j])&ROW_MASK;wr=int(a['wr_addr'][j])&ROW_MASK
 per_set=[sum(v for word,v in pending.items() if ((word//LANES)&1)==b) for b in (0,1)]
 assert per_set==[int(a['pending0'][j]),int(a['pending1'][j])],(int(c),per_set,int(a['pending0'][j]),int(a['pending1'][j]))
 exact=sum(pending.get(rd*LANES+l,0) for l in range(LANES))
 current_same=bool(a['wr_valid'][j] and wr==rd)
 blocked=bool(a['psum_rd_order_block'][j])
 if a['wr_valid'][j] and not a['wr_ready'][j]:
  stats['write_backpressure']+=1
  if a['acc_result_credit'][j]==0 and not a['acc_result_commit'][j]:stats['write_backpressure_no_result_credit']+=1
 if blocked:
  assert a['rd_valid'][j]
  kind='same_row_pending' if exact else ('same_row_current_only' if current_same else 'different_rows_only')
  stats[kind]+=1
  if a['dma_busy'][j]==0:stats[kind+'_dma_idle']+=1
  psum_only=(a['post_txn_count'][j]>0 and not a['post_head_psum_ready'][j] and a['post_head_scaled_ready'][j] and (a['acc_result_credit'][j]>0 or a['acc_result_commit'][j]))
  if psum_only:stats[kind+'_psum_only']+=1
  if kind not in examples:
   examples[kind]=dict(cycle=int(c),relative=int(c-cfg),read_row=rd,read_byte_offset=rd*64,write_row=wr,current_write_valid=int(a['wr_valid'][j]),same_row_pending_lanes=exact,pending_rows=sorted(set(word//LANES for word in pending if pending[word])),pending_lane_counts=per_set)
  if (args.m==256 and 635440<=c<635500) or (args.m==4 and 18740<=c<18810):detail.append(dict(cycle=int(c),kind=kind,read_row=rd,write_row=wr,pending_rows=sorted(set(word//LANES for word in pending if pending[word]))))
 if a['reserve'][j]:
  for lane in range(LANES):pending[wr*LANES+lane]+=1
 bits=a['bank_addr'][j];assert len(bits)==BANKS*BANK_ADDR_BITS,len(bits)
 code=int(a['commits'][j])
 for bank in range(BANKS):
  k=(code>>(bank*3))&7
  if k in (2,3):
   hi=len(bits)-bank*BANK_ADDR_BITS;field=bits[hi-BANK_ADDR_BITS:hi];assert set(field)<=set('01'),(int(c),bank,field)
   word=int(field,2)*BANKS+bank;assert pending[word]>0,(int(c),bank,word,dict(pending))
   assert ((word//LANES)&1)==(k&1)
   pending[word]-=1
   if not pending[word]:del pending[word]
assert not pending,pending
assert sum(stats[k] for k in ['same_row_pending','same_row_current_only','different_rows_only'])==d['node_stalls']['psum_rd_order_block']
result=dict(case=case,stats=dict(stats),examples=examples,detail=detail,physical_pending_counter_checks=len(cycles),pending_empty_at_done=True,units='64-byte PSUM rows; addresses masked to physical 1MiB LMEM; counters count lanes, not entire requests')
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='detail'}),flush=True)
