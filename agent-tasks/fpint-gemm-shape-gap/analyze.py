#!/usr/bin/env python3
"""Sample existing FSDBs strictly before rising edges; no simulator reruns."""
import argparse, json, re, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
TASK=Path(__file__).resolve().parent
BASE=ROOT/'agent-tasks/gemm-naive-improve-baseline'
CORE='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
RUNS={'improve4':'p4-candidate/improve-m4-iteration1','improve256':'p4-candidate/improve-m256-iteration1',
'naive4':'p4-regression/naive-m4-final1','naive256':'p4-regression/naive-m256-final1'}
def analyze(name):
 run=BASE/RUNS[name];wave=run/'wave.fsdb';out=TASK/'captures'/name;out.mkdir(parents=True,exist_ok=True)
 manifest=json.loads((run/'manifest.json').read_text());assert manifest['passed'] and not manifest['source_changes_during_run']
 lines=[l for l in (run/'simv.log').read_text().splitlines() if l.startswith('GEMM_LATENCY_DONE ')]
 assert len(lines)==1
 log=dict(re.findall(r'(\w+)=([^\s]+)',lines[0]));start,end=int(log['e_cfg']),int(log['e_valid'])
 edges=np.arange(start,end,dtype=np.int64); times=edges*10000+5000
 naive=name.startswith('naive');node=CORE+('/gemm_node_naive' if naive else '/gemm_node')
 compute=node+('/u_VX_gemm_compute_core' if naive else '/u_VX_gemm_unit_v2/u_compute_core')
 paths={'cfg':node+('/cfg_start_fire' if naive else '/u_VX_gemm_ctrl/cfg_fire'),
 'done':node+('/done_if/valid' if naive else '/u_VX_gemm_ctrl/done_if/valid'),
 'store':node+('/output_store_done' if naive else '/u_VX_gemm_ctrl/output_store_done_i')}
 for k in ['input_fire','in_pipe_ready_in','in_pipe_valid_out','input_stage_ready','prealigner_out_valid','pre_meta_valid_out','compute_ready','compute_fire','weight_ready','zero_ready','zp_consume_channel_ready','tree_credit_q','credit_return_q','int2fp_result_count','int2fp_result_pop','post_txn_space','rd_hold_valid','post_head_d3_raw_stall','qcol_scale_ready','out_scaler_input_ready','post_txn_count','post_head_scaled_ready','post_head_psum_ready','acc_result_credit','acc_result_commit','post_txn_launch','acc_write_fire']:
  paths[k]=compute+'/'+k
 for port in ['input_bus_if','weight_bus_if','scale_bus_if','zero_bus_if']:
  for sig in ['req_valid','req_ready']:paths[port+'_'+sig]=compute+'/'+port+'/'+sig
 for k in ['rd_req_valid','rd_req_ready','rd_rsp_valid','rd_rsp_ready','wr_req_valid','wr_req_ready']:
  paths['acc_'+k]=compute+'/acc_if/'+k
 for k in ['input_admission_ready','tagged_writeback']:paths[k]=node+'/gemm_unit_v2_if/'+k
 paths['external_busy']=CORE+('/accel_perf.cpu_dma.busy' if naive else '/accel_perf.hbm_dma.aggregate.busy')
 samples={};missing=[]
 for key,path in paths.items():
  cache=out/(key+'.npz')
  if cache.exists():
   a=np.load(cache);t,v=a['t'],a['v']
  else:
   r=fsdb_cli.report(str(wave),[path]);
   if not r.data_rows:missing.append(key);continue
   assert r.time_unit=='1ps',r.time_unit
   t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
   v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
   np.savez_compressed(cache,t=t,v=v)
  idx=np.searchsorted(t,times,side='left')-1
  a=v[np.maximum(idx,0)];a[idx<0]=-1;samples[key]=a
  if np.any(a<0):print(name,'unknown',key,int(np.sum(a<0)),flush=True)
 np.savez_compressed(out/'samples.npz',**samples)
 def count(mask):return int(np.sum(mask))
 s=samples;iv=s['input_bus_if_req_valid']==1;ir=s['input_bus_if_req_ready']==1
 assert s['cfg'][0]==1 and count(s['cfg']==1)==1
 inp=np.flatnonzero(iv&ir)
 assert len(inp)==manifest['m']*512*512//256
 masks={'input_fire':iv&ir,'input_backpressure':iv&~ir,'input_no_supply_ready':~iv&ir,'input_neither':~iv&~ir,
 'compute_fire':s['compute_fire']==1,'compute_wait_credit':(s['prealigner_out_valid']==1)&(s['pre_meta_valid_out']==1)&(s['tree_credit_q']==0)&(s['credit_return_q']==0),
 'compute_wait_weight':(s['prealigner_out_valid']==1)&(s['pre_meta_valid_out']==1)&(s['weight_ready']==0),
 'compute_wait_zero':(s['prealigner_out_valid']==1)&(s['pre_meta_valid_out']==1)&(s['zero_ready']==0),
 'post_wait_psum':(s['post_txn_count']>0)&(s['post_head_psum_ready']==0),
 'post_wait_scaled':(s['post_txn_count']>0)&(s['post_head_scaled_ready']==0),
 'post_wait_result_credit':(s['post_txn_count']>0)&(s['acc_result_credit']==0)&(s['acc_result_commit']==0),
 'int2fp_wait_post_space':(s['int2fp_result_count']>0)&(s['post_txn_space']==0),
 'int2fp_wait_read_hold':(s['int2fp_result_count']>0)&(s['rd_hold_valid']==1),
 'int2fp_wait_scale':(s['int2fp_result_count']>0)&(s['qcol_scale_ready']==0),
 'acc_write_fire':s['acc_write_fire']==1,'store':s['store']==1}
 for k in ['rd_req','rd_rsp']:
  masks['acc_'+k+'_fire']=(s['acc_'+k+'_valid']==1)&(s['acc_'+k+'_ready']==1)
  masks['acc_'+k+'_stall']=(s['acc_'+k+'_valid']==1)&(s['acc_'+k+'_ready']==0)
 if 'acc_wr_req_valid' in s and 'acc_wr_req_ready' in s:
  masks['acc_wr_stall']=(s['acc_wr_req_valid']==1)&(s['acc_wr_req_ready']==0)
 if 'external_busy' in s:
  masks['external_busy']=s['external_busy']==1;masks['input_stall_external_idle']=iv&~ir&(s['external_busy']==0)
 gaps=np.diff(inp);uniq,cnt=np.unique(gaps,return_counts=True)
 result={'run':str(run.relative_to(ROOT)),'wave':str(wave.relative_to(ROOT)),'log':log,'cycles':end-start,'missing':missing,
 'counts':{k:count(v) for k,v in masks.items()},'input_first':int(inp[0]),'input_last':int(inp[-1]),'input_span':int(inp[-1]-inp[0]+1),
 'input_gap_hist':dict(zip(map(str,uniq.tolist()),cnt.tolist())),
 'sampling':'Strict preedge, 10ns period, first rising edge at 5ns; cfg checked against FSDB.',
 'steady_middle_half':{k:count(v[(inp[0]+(inp[-1]-inp[0])//4):(inp[0]+3*(inp[-1]-inp[0])//4)]) for k,v in masks.items()}}
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(name,json.dumps(result),flush=True)
 return result
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('names',nargs='*');args=ap.parse_args()
 with ThreadPoolExecutor(max_workers=4) as pool:r=list(pool.map(analyze,args.names or RUNS))
 (TASK/'summary.json').write_text(json.dumps(r,indent=2)+'\n')
