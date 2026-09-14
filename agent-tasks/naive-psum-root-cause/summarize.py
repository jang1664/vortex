"""Summarize blockers, service and tag-matched PSUM read latency."""
from pathlib import Path
import json
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
BASE=ROOT/'agent-tasks/naive-input-single-cycle-issue/captures/m256'
c=np.arange(21191,627578,dtype=np.int64);t=c*10000+5000
def read(k):
    p=TASK/'captures'/(k+'.npz')
    if not p.exists():p=BASE/(k+'.npz')
    z=np.load(p);i=np.searchsorted(z['t'],t,side='left')-1
    assert (i>=0).all();v=z['v'][i]
    if k!='rsp_slot':assert (v>=0).all(),k
    return v
def cnt(m):return int(np.count_nonzero(m))
def stat(x):
    x=np.array(x)
    return dict(n=len(x),min=int(x.min()),mean=float(x.mean()),median=float(np.median(x)),p90=float(np.percentile(x,90)),p99=float(np.percentile(x,99)),max=int(x.max()))
s={p.stem:read(p.stem) for p in (TASK/'captures').glob('*.npz')}
for k in ['req_valid','req_ready','post_txn_count','post_head_psum_ready','post_head_scaled_ready','tree_credit_q','credit_return_q','acc_result_credit','weight_ready']:s[k]=read(k)
stream=(c>=22773)&(c<626847);bp=stream&(s['req_valid']==1)&(s['req_ready']==0)
counts={}
for k in ['int2fp_launch_ready','post_txn_space','rd_hold_valid','post_head_d3_raw_stall','qcol_scale_ready','out_scaler_input_ready']:
    bad=(s[k]==1) if k in ['rd_hold_valid','post_head_d3_raw_stall'] else (s[k]==0)
    counts['bp_'+k+'_blocking']=cnt(bp&bad)
for k in ['rd_issue_candidate_raw_block','psum_rd_order_block','psum_write_table_full','psum_write_waw_block','psum_write_war_block']:counts[k]=cnt(s[k])
counts['psum_read_request_bp']=cnt((s['rd_req_valid']==1)&(s['rd_req_ready']==0))
counts['psum_write_request_bp']=cnt((s['wr_req_valid']==1)&(s['wr_req_ready']==0))
counts['join_no_free_slot']=cnt(s['join_free_slot_valid']==0)
counts['join_issue_wait']=cnt((s['join_issue_slot_valid']==1)&(s['join_issue_all_done']==0))
counts['join_lane_rsp_bp']=cnt((s['join_lane_rsp_valid_mon']&~s['join_lane_rsp_ready_int'])!=0)
lat=[];pending={};alloc={};queue=[]
for i in range(len(c)):
    if 'prefetch_free_slot' in s and s['prefetch_alloc'][i]:alloc[int(s['prefetch_free_slot'][i])]=int(c[i])
    if s['rd_lmem_fire'][i]:
        tag=int(s['rd_issue_slot'][i]);assert tag not in pending
        pending[tag]=int(c[i])
        if tag in alloc:queue.append(int(c[i])-alloc.pop(tag))
    if s['rsp_lmem_fire'][i]:
        tag=int(s['rsp_slot'][i]);lat.append(int(c[i])-pending.pop(tag))
assert not pending
banks=[]
for k in ['per_bank_req_ready','per_bank_req_rw']:
    z=np.load(TASK/'captures'/(k+'.npz'));known=z['known'][np.searchsorted(z['t'],t,side='left')-1]
    assert np.all((s['per_bank_req_valid']&~known)==0),'Unknown '+k+' on valid request'
for b in range(16):
    valid=((s['per_bank_req_valid']>>b)&1)==1;ready=((s['per_bank_req_ready']>>b)&1)==1;wr=((s['per_bank_req_rw']>>b)&1)==1
    banks.append(dict(bank=b,reads=cnt(valid&ready&~wr),writes=cnt(valid&ready&wr),stall=cnt(valid&~ready),idle=cnt(~valid)))
root=[]
for b in [0,8]:
    v=s[f'bank{b}_root_valid'];r=s[f'bank{b}_root_read'];w=s[f'bank{b}_root_write'];sel=1<<s[f'bank{b}_selected_root'];fire=s[f'bank{b}_grant_fire']==1
    rw=(v&r)!=0;ww=(v&w)!=0
    rg=fire&((r&sel)!=0);wg=fire&((w&sel)!=0);ng=fire&~rg&~wg
    root.append(dict(bank=b,read_grants=cnt(rg),write_grants=cnt(wg),normal_grants=cnt(ng),
                     read_wait=cnt(rw&~rg),read_wait_write_grant=cnt(rw&wg),read_wait_normal_grant=cnt(rw&ng),
                     read_wait_no_grant=cnt(rw&~fire),out_buffer_stall=cnt(s[f'bank{b}_buffer_ready']==0)))
ports=[]
if 'port0_in0_req_valid' in s:
    for p in [0,8]:
        a=s[f'port{p}_in0_req_valid']==1;ar=s[f'port{p}_in0_req_ready']==1
        n=s[f'port{p}_in1_req_valid']==1;nr=s[f'port{p}_in1_req_ready']==1
        ov=s[f'port{p}_out0_req_valid']==1;orr=s[f'port{p}_out0_req_ready']==1
        ports.append(dict(port=p,psum_accept=cnt(a&ar),normal_accept=cnt(n&nr),psum_wait=cnt(a&~ar),normal_wait=cnt(n&~nr),
                          normal_wait_psum_accept=cnt(n&~nr&a&ar),output_fire=cnt(ov&orr),output_wait=cnt(ov&~orr)))
out=dict(counts=counts,read_accept_to_wide_response=stat(lat),prefetch_to_read_accept=stat(queue) if queue else None,banks=banks,roots=root,ports=ports)
(TASK/'summary.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
