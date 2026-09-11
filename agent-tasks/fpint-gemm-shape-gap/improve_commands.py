#!/usr/bin/env python3
"""Attribute improve input gaps to microtile boundaries using carried metadata."""
import json,re
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from analyze import BASE,CORE,RUNS,TASK,fsdb_cli

def run(name):
 out=TASK/'captures'/name;result=json.loads((out/'result.json').read_text());start=int(result['log']['e_cfg']);end=int(result['log']['e_valid']);times=np.arange(start,end)*10000+5000
 node=CORE+'/gemm_node';paths={'seq':node+'/gemm_unit_v2_if/packet_ctrl.work_seq','last':node+'/gemm_unit_v2_if/packet_ctrl.last','start':node+'/input_cmd_start','count':node+'/gemm_ctrl_if/input_read_ctrl.cmd.eff_mt'}
 data={}
 for k,path in paths.items():
  cache=out/('commands_'+k+'.npz')
  if cache.exists():a=np.load(cache);t,v=a['t'],a['v']
  else:
   r=fsdb_cli.report(str(BASE/RUNS[name]/'wave.fsdb'),[path]);assert r.data_rows,path
   t=np.array([int(x[0]) for x in r.data_rows]);v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows]);np.savez_compressed(cache,t=t,v=v)
  idx=np.searchsorted(t,times,side='left')-1;data[k]=v[np.maximum(idx,0)]
 samples=np.load(out/'samples.npz');fires=np.flatnonzero(samples['input_fire']==1)
 assert np.all(data['seq'][fires]>=0)
 boundary=data['seq'][fires[1:]]!=data['seq'][fires[:-1]];gap=np.diff(fires)
 def hist(a):u,n=np.unique(a,return_counts=True);return dict(zip(map(str,u.tolist()),n.tolist()))
 r={'name':name,'command_count':int(np.sum(data['start']==1)), 'rows_per_command':hist(data['count'][data['start']==1]),'within_command_gap_hist':hist(gap[~boundary]),'between_command_gap_hist':hist(gap[boundary]),'input_empty_cycles_between_commands':int(np.sum(gap[boundary]-1)),'input_empty_cycles_within_commands':int(np.sum(gap[~boundary]-1)),'last_matches_boundary':bool(np.all(data['last'][fires[:-1]][boundary]==1))}
 (out/'command-gaps.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r),flush=True)
with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,['improve4','improve256']))
