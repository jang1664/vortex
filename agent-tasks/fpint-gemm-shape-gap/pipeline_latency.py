#!/usr/bin/env python3
"""Measure tagged minimum input-to-PSUM-demand/add/write latencies."""
import json,re
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from analyze import BASE,CORE,TASK,RUNS,fsdb_cli

def run(name):
 runpath=BASE/RUNS[name];r=json.loads((TASK/'captures'/name/'result.json').read_text());cfg=int(r['log']['e_cfg']);first=cfg;length=6500 if name=='improve4' else 10000
 times=np.arange(first,first+length)*10000+5000;naive=name.startswith('naive');node=CORE+('/gemm_node_naive' if naive else '/gemm_node');compute=node+('/u_VX_gemm_compute_core' if naive else '/u_VX_gemm_unit_v2/u_compute_core');out=TASK/'captures'/name/'pipeline-latency';out.mkdir(parents=True,exist_ok=True)
 paths={}
 stages={'input':('input_fire','admitted_ctrl.acc_txn_tag'),'compute':('compute_fire','pre_meta_out.ctrl.acc_txn_tag'),'merge':('merged_fifo_pop','merged_fifo_data_out.ctrl.acc_txn_tag'),'demand_stage':('int2fp_result_pop','int2fp_result_data_out.ctrl.acc_txn_tag'),'add':('post_txn_launch','post_head_ctrl.acc_txn_tag'),'write':('acc_write_fire','acc_result_data_out.ctrl.acc_txn_tag')}
 for stage,(valid,tag) in stages.items():paths[stage+'_valid']=compute+'/'+valid;paths[stage+'_tag']=compute+'/'+tag
 paths['input_rd_en']=compute+'/admitted_ctrl.acc_rd_en';paths['add_rd_en']=compute+'/post_head_ctrl.acc_rd_en'
 samples={}
 for key,path in paths.items():
  cache=out/(key+'.npz')
  if cache.exists():a=np.load(cache);t,v=a['t'],a['v']
  else:
   report=fsdb_cli.report(str(runpath/'wave.fsdb'),[path],bt=f'{max(first-10,0)*10}ns',et=f'{(first+length+1)*10}ns');assert report.data_rows,path
   t=np.array([int(x[0]) for x in report.data_rows],dtype=np.int64);v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in report.data_rows],dtype=np.int64);np.savez_compressed(cache,t=t,v=v)
  idx=np.searchsorted(t,times,side='left')-1;samples[key]=v[np.maximum(idx,0)]
 records={}
 for stage in stages:
  for edge in np.flatnonzero(samples[stage+'_valid']==1):
   tag=int(samples[stage+'_tag'][edge]);d=records.setdefault(tag,{'tag':tag});assert stage not in d;d[stage]=int(edge)
   if stage=='input':d['rd_en']=int(samples['input_rd_en'][edge])
   if stage=='add':d['actual_add']=int(samples['add_rd_en'][edge])
 def summarize(rows):
  result={}
  for stage in list(stages)[1:]:
   selected=[d for d in rows if 'input' in d and stage in d]
   minimum=min(d[stage]-d['input'] for d in selected);example=next(d for d in selected if d[stage]-d['input']==minimum)
   result[stage]={'minimum_cycles':minimum,'example':example,'pairs':len(selected)}
  return result
 result={'name':name,'start_cfg_offset':0,'window_cycles':length,'all':summarize(list(records.values())),'psum_reads':summarize([d for d in records.values() if d.get('rd_en')==1])}
 (out/'records.json').write_text(json.dumps(list(records.values()),indent=2)+'\n');(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,['naive4','improve4']))
