#!/usr/bin/env python3
"""Actual retained M4 LOAD bank-commit/front-end completion ordering."""
import argparse,importlib.util,json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
TASK=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location('b',TASK/'p4-visibility-check.py');b=importlib.util.module_from_spec(sp);sp.loader.exec_module(b)
parser=argparse.ArgumentParser();parser.add_argument('--run',type=Path,default=TASK/'p4-candidate/m4-iteration1');args=parser.parse_args()
run=args.run;saved=json.loads((run/'physical-visibility-signals.json').read_text());wave=Path(saved['wave']);assert b.sha(wave)==saved['wave_sha256']
out=run/'load-fence';out.mkdir(exist_ok=True)
node=b.CORE+'/u_VX_dma_node';fence=node+'/write_fence'
paths={'bank_tag':b.LOCAL+'/per_bank_req_tag','worker_done':node+'/worker_done_if/valid','worker_ready':node+'/worker_done_if/ready','front_done':node+'/done_if/valid','front_ready':node+'/done_if/ready','return_commits':node+'/dma_bank_commit'}
for k in ('pending_r','reserved_r','reserve','lane_count','drained'):paths[k]=fence+'/'+k
for key in ('req_valid','req_data.rw','req_data.byteen'):paths['wide_'+key]=node+'/lmem_wide_bus_if/'+key

def read(item):
 key,path=item;r=b.fsdb_cli.report(str(wave),[path]);assert r.data_rows,path
 return key,dict(path=path,values=r.data_rows)
if (out/'signals.json').exists():
 cached=json.loads((out/'signals.json').read_text());assert cached['wave_sha256']==saved['wave_sha256'];extra=cached['signals']
else:
 with ThreadPoolExecutor(max_workers=4) as pool:extra=dict(pool.map(read,paths.items()))
 (out/'signals.json').write_text(json.dumps(dict(wave_sha256=saved['wave_sha256'],signals=extra)))
signals={**saved['signals'],**extra};physical_pending=0;reserved=committed=0;previous_bank_mask=0;worker_seen=False;worker=None;jobs=[]
for edge,time,v in b.sample(signals):
 if b.number(v,'reset')!=0:continue
 n=lambda k:b.number(v,k)
 bank_mask=0
 for bank in range(16):
  if b.number(v,'bank_valid',1,bank)==b.number(v,'bank_ready',1,bank)==b.number(v,'bank_rw',1,bank)==1:
   tag=b.number(v,'bank_tag',12,bank);assert tag is not None
   is_dma=((tag>>10)&1)==1 and ((tag>>8)&3)==1
   if is_dma:bank_mask|=1<<bank
 assert n('return_commits')==bank_mask,(edge,n('return_commits'),bank_mask)
 previous_bank_mask=bank_mask
 # Both the physical RAM write and the combinational commit return are
 # sampled at this same edge; pending_r describes earlier edges only.
 assert n('pending_r')==physical_pending,edge
 reserve_count=0
 if n('reserve'):
  mask=n('wide_req_data.byteen');assert mask is not None
  reserve_count=sum(bool((mask>>(8*i))&255) for i in range(16))
  assert n('wide_req_valid')==n('wide_req_data.rw')==1 and n('reserved_r')==0
  assert reserve_count==n('lane_count')
 if n('worker_done') and not worker_seen:
  worker=dict(worker_edge=edge,store=bool(n('dma_active_dir')),physical_pending_at_worker=physical_pending,fence_pending_at_worker=n('pending_r'))
 if n('front_done'):
  assert worker is not None and physical_pending==0 and n('pending_r')==0 and n('reserved_r')==0 and reserve_count==0
 if n('front_done') and n('front_ready'):
  worker.update(frontend_edge=edge,worker_to_frontend=edge-worker['worker_edge']);jobs.append(worker);worker=None
 worker_seen=bool(n('worker_done'))
 physical_pending+=reserve_count-bank_mask.bit_count();reserved+=reserve_count;committed+=bank_mask.bit_count()
 assert physical_pending>=0
assert physical_pending==0 and reserved==committed and worker is None
loads=[j for j in jobs if not j['store']];assert len(loads)==64 and len(jobs)==68
result=dict(status='pass',wave_sha256=saved['wave_sha256'],reserved_load_words=reserved,physical_committed_load_words=committed,load_completions=len(loads),store_completions=len(jobs)-len(loads),loads_with_uncommitted_writes_at_worker=sum(j['physical_pending_at_worker']>0 for j in loads),max_worker_to_frontend=max(j['worker_to_frontend'] for j in loads),jobs=jobs,scope='Actual M4 bank-tag-classified commits and current physical fence/front-end handshake; combinational commit return checked against the same physical bank edge. No injected stalls or T-ready command-identity proof.')
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='jobs'},indent=2))
