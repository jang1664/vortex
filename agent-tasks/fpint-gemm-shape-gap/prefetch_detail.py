#!/usr/bin/env python3
"""Track one skipped prefetch through its eventual demand using actual work tags."""
import json,re
import numpy as np
from analyze import BASE,CORE,TASK,RUNS,fsdb_cli
name='naive256';source=BASE/RUNS[name];out=TASK/'captures'/name/'prefetch';out.mkdir(parents=True,exist_ok=True)
r=json.loads((TASK/'captures'/name/'result.json').read_text());cfg=int(r['log']['e_cfg']);first=cfg+49900;length=400;times=np.arange(first,first+length)*10000+5000
node=CORE+'/gemm_node_naive';acc=node+'/u_VX_gemm_acc_lmem'
paths={k:acc+'/'+k for k in ['read_slot_tag','read_slot_valid','read_slot_completed','read_slot_demanded','prefetch_alloc','prefetch_capacity','late_read_alloc','read_req_slot_found','read_free_valid']}
for k in ['txn_accept_valid','txn_accept_tag','txn_accept_rd_en','rd_req_valid','rd_req_ready','rd_req_tag','rd_rsp_valid','rd_rsp_ready','rd_rsp_tag']:paths[k]=node+'/gemm_acc_if/'+k
samples={}
for key,path in paths.items():
 cache=out/(key+'.json')
 if cache.exists():raw=json.loads(cache.read_text())
 else:
  report=fsdb_cli.report(str(source/'wave.fsdb'),[path],bt=f'{(first-10)*10}ns',et=f'{(first+length+1)*10}ns');assert report.data_rows,path
  raw=[[int(t),int(v,2) if re.fullmatch('[01]+',v) else -1] for t,v in report.data_rows];cache.write_text(json.dumps(raw))
 t=np.array([x[0] for x in raw]);v=[x[1] for x in raw];idx=np.searchsorted(t,times,side='left')-1;samples[key]=[v[i] if i>=0 else -1 for i in idx]
s=samples;tag=9993;events=[]
for i in range(length):
 accept=s['txn_accept_valid'][i]==1 and s['txn_accept_tag'][i]==tag
 demand=s['rd_req_valid'][i]==1 and s['rd_req_tag'][i]==tag
 response=s['rd_rsp_valid'][i]==1 and s['rd_rsp_tag'][i]==tag
 if accept or demand or response:
  slots=[]
  for slot in range(8):
   if s['read_slot_valid'][i]&(1<<slot):slots.append({'slot':slot,'tag':(s['read_slot_tag'][i]>>(32*slot))&0xffffffff,'completed':bool(s['read_slot_completed'][i]&(1<<slot)),'demanded':bool(s['read_slot_demanded'][i]&(1<<slot))})
  events.append({'cfg_offset':49900+i,'input_accept':accept,'prefetch_alloc':s['prefetch_alloc'][i],'prefetch_capacity':s['prefetch_capacity'][i],'read_demand':demand,'read_ready':s['rd_req_ready'][i],'late_read_alloc':s['late_read_alloc'][i],'read_response':response,'rsp_ready':s['rd_rsp_ready'][i],'slots':slots})
assert any(e['input_accept'] for e in events) and any(e['read_response'] for e in events)
result={'work_tag':tag,'events':events};(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
for e in events:
 print(e['cfg_offset'],'input',e['input_accept'],'prefetch',e['prefetch_alloc'],'demand',e['read_demand'],'ready',e['read_ready'],'response',e['read_response'],'slots',[(x['tag'],x['completed'],x['demanded']) for x in e['slots']],flush=True)
