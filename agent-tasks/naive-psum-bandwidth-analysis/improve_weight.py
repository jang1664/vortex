"""Measure the unchanged improve weight response queue for comparison."""
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from analyze import BASE, CORE, RUNS, TASK, fsdb_cli

def run(name):
    source=BASE/RUNS[name]
    result=json.loads((TASK/'captures'/name/'result.json').read_text())
    times=np.arange(int(result['log']['e_cfg']),int(result['log']['e_valid']))*10000+5000
    root=CORE+'/gemm_node/u_tmem_subsystem/u_ldma_weight'
    paths={k:root+'/u_stream_queue/'+k for k in ['fetch_head_valid','request_slot_available','slot_count_r']}
    paths.update({k:root+'/'+k for k in ['dbg_overlap_early_slot_release','dbg_overlap_response_stage_bypass']})
    for k in ['req_valid','req_ready','rsp_valid','rsp_ready']:
        paths[k]=root+'/lmem_bus_if/'+k
    out=TASK/'captures'/name/'weight';out.mkdir(parents=True,exist_ok=True)
    data={}
    for key,path in paths.items():
        cache=out/(key+'.npz')
        if cache.exists():
            a=np.load(cache);t,v=a['t'],a['v']
        else:
            r=fsdb_cli.report(str(source/'wave.fsdb'),[path]);assert r.data_rows,path
            t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
            v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
            np.savez_compressed(cache,t=t,v=v)
        idx=np.searchsorted(t,times,side='left')-1;assert np.all(idx>=0)
        data[key]=v[idx];assert np.all(data[key]>=0),key
    u,c=np.unique(data['slot_count_r'],return_counts=True)
    r={'name':name,'slot_occupancy':dict(zip(map(str,u.tolist()),c.tolist())),
       'fetch_blocked_no_slot':int(np.sum((data['fetch_head_valid']==1)&(data['request_slot_available']==0))),
       'read_fire':int(np.sum((data['req_valid']==1)&(data['req_ready']==1))),
       'read_stall':int(np.sum((data['req_valid']==1)&(data['req_ready']==0))),
       'early_release':np.unique(data['dbg_overlap_early_slot_release']).tolist(),
       'response_bypass':np.unique(data['dbg_overlap_response_stage_bypass']).tolist()}
    (out/'queue-result.json').write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps(r),flush=True)

if __name__=='__main__':
    with ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(run,['improve4','improve256']))
