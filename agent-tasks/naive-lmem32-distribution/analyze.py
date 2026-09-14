"""Cache FSDB evidence for the independent naive LMEM port/bank matrix.

All counts use the half-open GEMM window [cfg, done), unless explicitly
labelled input_stream. Handshakes are sampled immediately before clock edges.
No consecutive Input handshake invariant is assumed. 'normal' counters mean
non-PSUM-read/write (including final-output writes and ordinary traffic).
"""
from pathlib import Path
import argparse, concurrent.futures, json, re, sys
import numpy as np
TASK=Path(__file__).resolve().parent; ROOT=TASK.parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('topology',choices=['p16_b16','p32_b16','p16_b32','p32_b32'])
ap.add_argument('case',choices=['m4','m256']);ap.add_argument('--iteration',default='v1')
ap.add_argument('--detail',action='store_true');args=ap.parse_args()
ports,banks=map(int,re.findall(r'\d+',args.topology))
run=TASK/'runs'/args.iteration/args.topology/args.case
out=TASK/'captures'/args.iteration/args.topology/args.case;out.mkdir(parents=True,exist_ok=True)
manifest=json.loads((run/'manifest.json').read_text()); result=json.loads((run/'result.json').read_text())
assert result['passed']
if manifest.get('state')=='recovered_complete':
 assert manifest.get('source_changes_original_to_recovery')==[]
 assert manifest.get('recovery',{}).get('recovered')
else:
 assert manifest.get('source_changes_during_run')==[]
done=[x for x in (run/'simv.log').read_text().splitlines() if x.startswith('GEMM_LATENCY_DONE ')]
assert len(done)==1
meta=dict(re.findall(r'(\w+)=([^\s]+)',done[0]));cfg,end,store=(int(meta[k]) for k in ['e_cfg','e_valid','e_store'])
c=np.arange(cfg,end+1,dtype=np.int64);times=c*10000+5000;whole=c<end
C='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
N=C+'/gemm_node_naive';G=N+'/u_VX_gemm_compute_core';A=N+'/u_VX_gemm_acc_lmem';L=C+'/mem_unit/local_mem'
paths={}
def cache(key,path):
 paths[key]=path;p=out/(key+'.npz')
 if not p.exists():
  r=fsdb_cli.report(str(run/'wave.fsdb'),[path]);assert r.data_rows and r.time_unit=='1ps',path
  # Preserve an explicit known-bit mask. Unused ready/rw values can be X.
  t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
  v=np.array([int(re.sub('[xXzZ]','0',x[1]),2) for x in r.data_rows],dtype=np.int64)
  known=np.array([int(''.join('1' if b in '01' else '0' for b in x[1]),2) for x in r.data_rows],dtype=np.uint64)
  np.savez_compressed(p,t=t,v=v,known=known)
 return p

def sample(key,path):
 z=np.load(cache(key,path));i=np.searchsorted(z['t'],times,side='left')-1;assert (i>=0).all(),key
 return z['v'][i]
def require_known(key, mask=None, bits=None):
 z=np.load(out/(key+'.npz'));i=np.searchsorted(z['t'],times,side='left')-1;k=z['known'][i]
 active=whole if mask is None else whole&mask
 required=int(z['known'].max()) if bits is None else bits
 assert np.all((k[active]&np.uint64(required))==required), 'Unknown consumed '+key
def cnt(mask):return int(np.count_nonzero(mask&whole))
def stats(x):
 a=np.asarray(x);return None if not len(a) else dict(n=len(a),min=int(a.min()),median=float(np.median(a)),mean=float(a.mean()),p90=float(np.percentile(a,90)),p99=float(np.percentile(a,99)),max=int(a.max()))
s={k:sample(k,G+'/'+k) for k in ['input_fire','acc_write_fire','prealigner_out_valid','weight_ready','post_txn_count','post_head_psum_ready','post_head_scaled_ready']}
s.update({k:sample(k,G+'/input_bus_if/'+k) for k in ['req_valid','req_ready']})
for k in ['input_fire','acc_write_fire','req_valid','req_ready','post_txn_count','post_head_psum_ready','post_head_scaled_ready','prealigner_out_valid','weight_ready']:require_known(k)
ie=c[s['input_fire']==1];ae=c[s['acc_write_fire']==1]
expected=manifest['m']*manifest['k']*manifest['n']//256
assert len(ie)==len(ae)==expected
bounds=[cfg,int(ie[0]),int(ie[-1]),int(ae[-1]),store,end];assert all(b>=a for a,b in zip(bounds,bounds[1:]))
phases=dict(zip(['startup','input_stream','compute_drain','output_tail','finalize'],map(int,np.diff(bounds))))
stream=(c>=ie[0])&(c<ie[-1]);bp=(s['req_valid']==1)&(s['req_ready']==0);weight=(s['prealigner_out_valid']==1)&(s['weight_ready']==0);psum=(s['post_txn_count']!=0)&(s['post_head_psum_ready']==0)
summary=dict(provenance={'recovered':bool(manifest.get('recovery',{}).get('recovered')), 'source_changes_during_run':manifest.get('source_changes_during_run'), 'recovery':manifest.get('recovery')},class_semantics={'normal':'all non-PSUM-read/write requests, including final output and ordinary traffic','arbitration_window':'representative banks 0,8,16,24 if present'},topology=args.topology,case=args.case,window='[cfg, done)',gemm_cycles=end-cfg,boundaries=dict(zip(['cfg','first_input','last_input','last_acc_write','store','done'],bounds)),phases=phases,input_count=expected)
summary['input_stream_activity']=dict(fire=cnt(stream&(s['input_fire']==1)),backpressure=cnt(stream&bp),no_supply=cnt(stream&(s['req_valid']==0)))
assert sum(summary['input_stream_activity'].values())==phases['input_stream']
summary['overlapping_stalls']={k:cnt(v) for k,v in dict(weight_wait=weight,psum_wait=psum,psum_only_wait=psum&(s['post_head_scaled_ready']==1),bp_weight_only=bp&weight&~psum,bp_psum_only=bp&psum&~weight,bp_both=bp&weight&psum,bp_neither=bp&~weight&~psum).items()}
dma_busy=sample('dma_busy',C+'/accel_perf.cpu_dma.busy')==1
summary['dma_busy_by_phase']={name:int(np.count_nonzero(dma_busy&(c>=lo)&(c<hi))) for name,lo,hi in zip(phases,bounds,bounds[1:])}
summary['dma_counters']={k:int((v:=sample('dma_'+k,C+'/accel_perf.cpu_dma.'+k))[-1]-v[0]) for k in ['rd_bytes','wr_bytes','xfer_count','active_cycles','src_rd_req_fire','src_rd_req_stall','dst_wr_fire','dst_wr_stall','wait_dcache','wait_lmem']}
a={k:sample(k,A+'/'+k) for k in ['prefetch_alloc','prefetch_free_slot','rd_lmem_fire','rd_issue_slot','rsp_lmem_fire','rsp_slot']}
for k in ['prefetch_alloc','rd_lmem_fire','rsp_lmem_fire']:require_known(k)
for tag,fire in [('prefetch_free_slot','prefetch_alloc'),('rd_issue_slot','rd_lmem_fire'),('rsp_slot','rsp_lmem_fire')]:require_known(tag,a[fire]==1)
pending={};alloc={};lat=[];queue=[]
for i in np.flatnonzero((a['prefetch_alloc']|a['rd_lmem_fire']|a['rsp_lmem_fire'])&whole):
 if a['prefetch_alloc'][i]:alloc[int(a['prefetch_free_slot'][i])]=int(c[i])
 if a['rd_lmem_fire'][i]:
  tag=int(a['rd_issue_slot'][i]);assert tag not in pending;pending[tag]=int(c[i]);queue.append(int(c[i])-alloc.pop(tag))
 if a['rsp_lmem_fire'][i]:lat.append(int(c[i])-pending.pop(int(a['rsp_slot'][i])))
assert not pending
summary['psum_read_accept_to_response']=stats(lat);summary['psum_prefetch_to_accept']=stats(queue)
summary['longest_psum_backpressure_window']=None
m=bp&psum&stream;edges=np.diff(np.r_[False,m,False].astype(int));starts=np.flatnonzero(edges==1);ends=np.flatnonzero(edges==-1)
if len(starts):
 j=int(np.argmax(ends-starts));summary['longest_psum_backpressure_window']=[int(c[starts[j]]),int(c[ends[j]])]

def write():
 (out/'paths.json').write_text(json.dumps(paths,indent=2)+'\n');(out/'analysis.json').write_text(json.dumps(summary,indent=2)+'\n');(TASK/(args.iteration+'-'+args.topology+'-'+args.case+'-analysis.json')).write_text(json.dumps(summary,indent=2)+'\n')
write();print(json.dumps(summary),flush=True)
if args.detail:
 bv=sample('bank_valid',L+'/per_bank_req_valid');br=sample('bank_ready',L+'/per_bank_req_ready');bw=sample('bank_rw',L+'/per_bank_req_rw')
 pv=sample('port_valid',L+'/req_valid_in');pr=sample('port_ready',L+'/req_ready_in');pw=sample('port_rw',L+'/req_rw')
 ppsumr=sample('port_psum_read',L+'/g_naive_psum_priority/psum_read');ppsumw=sample('port_psum_write',L+'/g_naive_psum_priority/psum_write')
 summary['ports']=[]
 for p in range(ports):
  require_known('port_ready',((pv>>p)&1)==1,1<<p);require_known('port_rw',((pv>>p)&1)==1,1<<p)
  require_known('port_psum_read',((pv>>p)&1)==1,1<<p);require_known('port_psum_write',((pv>>p)&1)==1,1<<p)
  valid=((pv>>p)&1)==1;ready=((pr>>p)&1)==1;rd=((ppsumr>>p)&1)==1;wr=((ppsumw>>p)&1)==1
  summary['ports'].append(dict(port=p,accept=cnt(valid&ready),wait=cnt(valid&~ready),psum_read_accept=cnt(valid&ready&rd),psum_write_accept=cnt(valid&ready&wr),normal_accept=cnt(valid&ready&~rd&~wr)))
 summary['banks']=[];summary['bank_arbitration']=[];summary['commits']={k:0 for k in ['psum0','psum1','final','dma']}
 for b in range(banks):
  require_known('bank_ready',((bv>>b)&1)==1,1<<b);require_known('bank_rw',((bv>>b)&1)==1,1<<b)
  valid=((bv>>b)&1)==1;ready=((br>>b)&1)==1;wr=((bw>>b)&1)==1
  summary['banks'].append(dict(bank=b,reads=cnt(valid&ready&~wr),writes=cnt(valid&ready&wr),wait=cnt(valid&~ready),idle=cnt(~valid)))
  d=L+f'/g_naive_commit[{b}]/g_routed/decode';commit=sample(f'bank{b}_commit',d+'/commit')
  for key,value in [('psum0',2),('psum1',3),('final',4),('dma',6)]:summary['commits'][key]+=cnt(commit==value)
  if b not in range(0,banks,8):continue
  d=L+f'/g_naive_psum_priority/req_xbar/g_bank[{b}]'
  z={k:sample(f'bank{b}_'+k,d+'/'+k) for k in ['root_valid','root_read','root_write','selected_root','grant_fire','buffer_ready']}
  require_known(f'bank{b}_root_valid');require_known(f'bank{b}_grant_fire')
  require_known(f'bank{b}_selected_root',z['grant_fire']==1)
  selected=1<<z['selected_root'];fire=z['grant_fire']==1;rg=fire&((z['root_read']&selected)!=0);wg=fire&((z['root_write']&selected)!=0);ng=fire&~rg&~wg;wait=((z['root_valid']&z['root_read'])!=0)&~rg
  summary['bank_arbitration'].append(dict(bank=b,read_grants=cnt(rg),write_grants=cnt(wg),normal_grants=cnt(ng),read_wait=cnt(wait),read_wait_write_grant=cnt(wait&wg),read_wait_normal_grant=cnt(wait&ng),read_wait_no_grant=cnt(wait&~fire),out_buffer_stall=cnt(z['buffer_ready']==0)))
  print('bank',b,'done',flush=True);write()
 # Record each S/Z source engine separately, including physical lane mapping.
 summary['qparam_engines']=[]
 for e in range(2):
  for lane in range(4):
   d=N+f'/quant_executor/g_engine[{e}]/source_if[{lane}]'
   v=sample(f'q{e}_lane{lane}_valid',d+'/req_valid')==1;r=sample(f'q{e}_lane{lane}_ready',d+'/req_ready')==1
   port=(24+e*4+lane) if ports>=32 else 8+lane
   summary['qparam_engines'].append(dict(engine='scale' if e==0 else 'zero',lane=lane,lmem_port=port,accept=cnt(v&r),wait=cnt(v&~r)))
 assert summary['commits']['psum0']+summary['commits']['psum1']==summary['psum_read_accept_to_response']['n']*8
 assert summary['commits']['final']==manifest['m']*manifest['n']//4
 assert summary['commits']['dma']==summary['dma_counters']['rd_bytes']//8
 summary['detail_complete']=True
 write();print(json.dumps(summary),flush=True)
