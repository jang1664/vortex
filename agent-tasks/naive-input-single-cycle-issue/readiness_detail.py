"""Separate Input admission/pipe stalls and quantify current lane skew."""
from pathlib import Path
import sys,json,re
import numpy as np
TASK=Path(__file__).resolve().parent;ROOT=TASK.parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import fsdb_cli
CAP=TASK/'captures/m256';s=dict(np.load(CAP/'sampled.npz'));c=s['cycles'];times=c*10000+5000
CORE='/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
N=CORE+'/gemm_node_naive';C=N+'/u_VX_gemm_compute_core';A=N+'/u_VX_gemm_acc_lmem'
paths={'admit_ready':N+'/acc_txn_accept_ready','pipe_ready':C+'/in_pipe_ready_in',
       'prefetch_free':A+'/prefetch_free_valid','txn_count':A+'/txn_count',
       'rd_enable':A+'/acc_if/txn_accept_rd_en'}
paths.update({k:C+'/'+k for k in ['tree_credit_q','credit_return_q','acc_result_credit','acc_result_commit','compute_ready']})
for k,path in paths.items():
    cache=CAP/(k+'.npz')
    if not cache.exists():
        r=fsdb_cli.report(str(TASK/'runs/v1/m256/wave.fsdb'),[path]);assert r.time_unit=='1ps' and r.data_rows
        t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
        v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
        np.savez_compressed(cache,t=t,v=v)
    z=np.load(cache);idx=np.searchsorted(z['t'],times,side='left')-1
    assert np.all(idx>=0)
    s[k]=z['v'][idx];assert np.all(s[k]>=0)
    print(k,'sampled',flush=True)
stream=(c>=22773)&(c<626847);bp=stream&(s['req_valid']==1)&(s['req_ready']==0)
assert np.array_equal(s['req_ready'],s['admit_ready']&s['pipe_ready'])
assert np.array_equal(s['admit_ready'],(s['txn_count']<64)&((s['rd_enable']==0)|(s['prefetch_free']==1)))
wait=stream&(s['fetch_active_r']==1)&(s['request_done']==0)
accepted=s['sent_r']|s['request_fire'];b=(s['request_byte_addr'][s['request_done']==1]//8)%16
counts={
 'input_backpressure':int(bp.sum()),
 'bp_admission_only':int((bp&(s['admit_ready']==0)&(s['pipe_ready']==1)).sum()),
 'bp_pipe_only':int((bp&(s['admit_ready']==1)&(s['pipe_ready']==0)).sum()),
 'bp_both':int((bp&(s['admit_ready']==0)&(s['pipe_ready']==0)).sum()),
 'bp_txn_full':int((bp&(s['txn_count']>=64)).sum()),
 'bp_required_psum_slot_unavailable':int((bp&(s['rd_enable']==1)&(s['prefetch_free']==0)).sum()),
 'max_txn_count':int(s['txn_count'].max()),
 'request_wait':int(wait.sum()),
 'request_wait_no_lane_accepted':int((wait&(accepted==0)).sum()),
 'request_wait_some_lane_accepted':int((wait&(accepted!=0)).sum()),
 'request_wait_previously_sent_lane':int((wait&(s['sent_r']!=0)).sum()),
 'consecutive_same_bank_group':int((b[1:]==b[:-1]).sum()),
 'consecutive_pairs':len(b)-1,
 'bp_tree_credit_unavailable':int((bp&(s['tree_credit_q']==0)&(s['credit_return_q']==0)).sum()),
 'bp_result_credit_unavailable':int((bp&(s['acc_result_credit']==0)&(s['acc_result_commit']==0)).sum()),
 'bp_compute_not_ready':int((bp&(s['compute_ready']==0)).sum()),
}
examples=[]
for i in np.flatnonzero(bp&(s['rd_enable']==1)&(s['prefetch_free']==0))[:8]:
    examples.append({'cycle':int(c[i]),**{k:int(s[k][i]) for k in paths}})
report={'interval':[22773,626847],'counts':counts,'examples':examples,'signal_paths':paths}
(TASK/'readiness-detail.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
