#!/usr/bin/env python3
"""Resolve naive PSUM response-slot throttling in a fixed steady window."""
import json,re,sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import fsdb_cli
from analyze import BASE,CORE,RUNS,TASK

def run(name):
 source=BASE/RUNS[name];node=CORE+'/gemm_node_naive'
 log=next(l for l in (source/'simv.log').read_text().splitlines() if l.startswith('GEMM_LATENCY_DONE '));cfg=int(re.search(r'e_cfg=(\d+)',log)[1])
 offset=50000 if name=='naive256' else 10000
 first=cfg+offset;length=4096;times=(np.arange(first,first+length)*10000+5000).astype(np.int64)
 out=TASK/'captures'/name/'physical';out.mkdir(parents=True,exist_ok=True)
 paths={}
 for k in ['slot_valid','free_slot_valid','wide_req_fire','issue_all_done','response_fifo_push','response_fifo_pop','response_fifo_full','complete_slot','issue_slot']:
  paths['join_'+k]=node+'/psum_rd_lane_split/'+k
 for bus in ['psum_rd_wide_bus_if','psum_rd_raw_bus_if','psum_wr_raw_bus_if']:
  for k in ['req_valid','req_ready','rsp_valid','rsp_ready','req_data.tag','rsp_data.tag']:
   if bus=='psum_wr_raw_bus_if' and k.startswith('rsp'):continue
   paths[bus+'_'+k.replace('.','_')]=node+'/'+bus+'/'+k
 for k in ['rd_issue_candidate_raw_block','read_slot_valid','read_slot_completed','read_slot_demanded','read_free_valid','read_req_slot_found','late_read_alloc','prefetch_alloc']:
  paths['acc_'+k]=node+'/u_VX_gemm_acc_lmem/'+k
 for k in ['req_valid','req_ready','rsp_valid','rsp_ready']:
  paths['lane0_'+k]=node+'/psum_rd_lane_mem_if[0]/'+k
 for k in ['rd_req_valid','rd_req_ready','rd_req_tag','rd_rsp_valid','rd_rsp_ready','rd_rsp_tag']:
  paths['core_'+k]=node+'/gemm_acc_if/'+k
 for k in ['per_bank_req_valid','per_bank_req_ready','per_bank_req_rw']:
  paths[k]=CORE+'/mem_unit/local_mem/'+k
 paths['external_busy']=CORE+'/accel_perf.cpu_dma.busy'
 samples={};missing=[]
 for key,path in paths.items():
  cache=out/(key+'.npz')
  if cache.exists():a=np.load(cache);t,v=a['t'],a['v']
  else:
   r=fsdb_cli.report(str(source/'wave.fsdb'),[path],bt=f'{(first-100)*10}ns',et=f'{(first+length+1)*10}ns')
   if not r.data_rows:missing.append(key);continue
   t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64);v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
   np.savez_compressed(cache,t=t,v=v)
  idx=np.searchsorted(t,times,side='left')-1;a=v[np.maximum(idx,0)];a[idx<0]=-1;samples[key]=a
 s=samples
 def hist(a):u,n=np.unique(a,return_counts=True);return dict(zip(map(str,u.tolist()),n.tolist()))
 def count(a):return int(np.sum(a))
 def gap(a):return hist(np.diff(np.flatnonzero(a)))
 rv=s['psum_rd_wide_bus_if_req_valid'];rr=s['psum_rd_wide_bus_if_req_ready'];fire=(rv==1)&(rr==1)
 pending={};lat=[]
 for i in range(length):
  if fire[i]:
   tag=int(s['psum_rd_wide_bus_if_req_data_tag'][i]);assert tag not in pending;pending[tag]=i
  if s['psum_rd_wide_bus_if_rsp_valid'][i]==1 and s['psum_rd_wide_bus_if_rsp_ready'][i]==1:
   tag=int(s['psum_rd_wide_bus_if_rsp_data_tag'][i])
   if tag in pending:lat.append(i-pending.pop(tag))
 r={'name':name,'start_cfg_offset':offset,'cycles':length,'missing':missing,
 'read_requests':count(fire),'read_req_gaps':gap(fire),'read_rsp_latency_hist':hist(np.array(lat)),
 'join_slot_occupancy':hist(np.array([int(v).bit_count() if v>=0 else -1 for v in s['join_slot_valid']])),
 'join_full':count(s['join_free_slot_valid']==0),'read_blocked':count((rv==1)&(rr==0)),
 'read_blocked_and_full':count((rv==1)&(rr==0)&(s['join_free_slot_valid']==0)),
 'response_fifo_full':count(s['join_response_fifo_full']==1),
 'read_raw_block':count(s['acc_rd_issue_candidate_raw_block']==1),
 'lane0_req_stall':count((s['lane0_req_valid']==1)&(s['lane0_req_ready']==0)),
 'write_stall':count((s['psum_wr_raw_bus_if_req_valid']==1)&(s['psum_wr_raw_bus_if_req_ready']==0)),
 'write_fire':count((s['psum_wr_raw_bus_if_req_valid']==1)&(s['psum_wr_raw_bus_if_req_ready']==1))}
 if 'external_busy' in s:r['external_busy']=count(s['external_busy']==1)
 valid=s['per_bank_req_valid']&s['per_bank_req_ready'];rw=s['per_bank_req_rw']
 r['bank_request_words']=int(sum(int(v).bit_count() for v in valid))
 r['bank_read_words']=int(sum(int(v).bit_count() for v in (valid&~rw)))
 r['bank_write_words']=int(sum(int(v).bit_count() for v in (valid&rw)))
 r['bank_request_hist']=hist(np.array([int(v).bit_count() for v in valid]))
 r['bank_accepted_by_index']=[count((valid&(1<<i))!=0) for i in range(16)]
 r['adapter_slot_occupancy']=hist(np.array([int(v).bit_count() for v in s['acc_read_slot_valid']]))
 und=s['acc_read_slot_valid']&s['acc_read_slot_completed']&~s['acc_read_slot_demanded']
 r['completed_undemanded_slot_occupancy']=hist(np.array([int(v).bit_count() for v in und]))
 blocked=(s['core_rd_req_valid']==1)&(s['core_rd_req_ready']==0)
 r['core_read_blocked']=count(blocked)
 r['core_read_blocked_full_no_matching_slot']=count(blocked&(s['acc_read_free_valid']==0)&(s['acc_read_req_slot_found']==0))
 r['late_read_allocations']=count(s['acc_late_read_alloc']==1)
 r['prefetch_allocations']=count(s['acc_prefetch_alloc']==1)
 pending={};lat=[]
 for i in range(length):
  if s['core_rd_req_valid'][i]==1 and s['core_rd_req_ready'][i]==1:
   tag=int(s['core_rd_req_tag'][i]);assert tag not in pending;pending[tag]=i
  if s['core_rd_rsp_valid'][i]==1 and s['core_rd_rsp_ready'][i]==1:
   tag=int(s['core_rd_rsp_tag'][i])
   if tag in pending:lat.append(i-pending.pop(tag))
 r['core_read_response_latency_hist']=hist(np.array(lat))
 np.savez_compressed(out/'samples.npz',**s);(out/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r),flush=True)
with ThreadPoolExecutor(max_workers=2) as p:list(p.map(run,['naive4','naive256']))
