"""Measure weight-gather bank mapping and command-to-install latency."""
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from analyze import BASE, CORE, RUNS, TASK, fsdb_cli

def run(name):
    source=BASE/RUNS[name]
    line=next(line for line in (source/'simv.log').read_text().splitlines() if line.startswith('GEMM_LATENCY_DONE '))
    result={'log':dict(re.findall(r'(\w+)=([^\s]+)',line))}
    first=int(result['log']['e_cfg']);end=int(result['log']['e_valid'])
    times=np.arange(first,end)*10000+5000
    node=CORE+'/gemm_node_naive';weight=node+'/weight_executor'
    paths={k:weight+'/'+k for k in ['admit','installed','installed_id','source_done_valid','source_done_work_seq','writer_release','head_valid','head_id']}
    paths.update({k:weight+'/transport/'+k for k in ['scheduler_work_seq','src_strides[0]']})
    for key in ['fetch_head_valid','request_slot_available','slot_count_r']:
        paths['queue_'+key]=weight+'/gather/u_stream_queue/'+key
    for i in range(4):
        for k in ['req_valid','req_ready','req_data.addr']:
            paths[f'lane{i}_{k}']=node+f'/w_lane_mem_if[{i}]/'+k
    out=TASK/'captures'/name/'weight';out.mkdir(parents=True,exist_ok=True)
    data={}
    def capture(item):
        key,path=item
        cache=out/(key+'.npz')
        if cache.exists():
            a=np.load(cache);t,v=a['t'],a['v']
        else:
            r=fsdb_cli.report(str(source/'wave.fsdb'),[path]);assert r.data_rows,path
            t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
            v=np.array([int(x[1],2) if re.fullmatch('[01]+',x[1]) else -1 for x in r.data_rows],dtype=np.int64)
            np.savez_compressed(cache,t=t,v=v)
        idx=np.searchsorted(t,times,side='left')-1;assert np.all(idx>=0)
        return key,v[idx]
    with ThreadPoolExecutor(max_workers=4) as pool:
        data=dict(pool.map(capture,paths.items()))
    def hist(a):
        u,c=np.unique(a,return_counts=True);return dict(zip(map(str,u.tolist()),c.tolist()))
    admit=np.flatnonzero(data['admit']==1)
    records={int(data['scheduler_work_seq'][i]):dict(admit=int(i),stride=int(data['src_strides[0]'][i])) for i in admit}
    for event,tag in [('source_done_valid','source_done_work_seq'),('installed','installed_id')]:
        for i in np.flatnonzero(data[event]==1):
            records[int(data[tag][i])][event]=int(i)
    banks=[];reqtimes=[];perlane=[]
    for lane in range(4):
        fire=(data[f'lane{lane}_req_valid']==1)&(data[f'lane{lane}_req_ready']==1)
        ix=np.flatnonzero(fire);perlane.append(ix)
        banks.extend((data[f'lane{lane}_req_data.addr'][fire]&15).tolist());reqtimes.extend(ix.tolist())
        assert len(ix)==len(admit)*4,(lane,len(ix),len(admit))
    rows=list(records.values())
    for j,r in enumerate(rows):
        chunk=np.concatenate([x[j*4:(j+1)*4] for x in perlane])
        r['first_request']=int(chunk.min());r['last_request']=int(chunk.max())
        r['banks']=sorted(set(int(data[f'lane{lane}_req_data.addr'][i])&15 for lane in range(4) for i in perlane[lane][j*4:(j+1)*4]))
    report={'name':name,'commands':len(admit),'stride_hist':hist([r['stride'] for r in rows]),
            'queue_slot_hist':hist(data['queue_slot_count_r']),
            'fetch_blocked_no_slot':int(np.sum((data['queue_fetch_head_valid']==1)&(data['queue_request_slot_available']==0))),
            'banks_per_command':hist([len(r['banks']) for r in rows]),
            'physical_read_words':len(banks),'bank_hist':hist(banks),
            'admit_to_install':hist([r['installed']-r['admit'] for r in rows]),
            'request_span':hist([r['last_request']-r['first_request']+1 for r in rows]),
            'source_done_to_install':hist([r['installed']-r['source_done_valid'] for r in rows]),
            'writer_head_blocked':int(np.sum((data['head_valid']==1)&(data['writer_release']==0))),
            'examples':list(records.items())[:12]}
    np.savez_compressed(out/'samples.npz',**data)
    (out/'records.json').write_text(json.dumps(records,indent=2)+'\n')
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)

if __name__=='__main__':
    for name in sys.argv[1:] or ['naive4','naive256']:run(name)
