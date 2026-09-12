"""Measure external DMA counters and physical LMEM service from FSDB."""
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from analyze import BASE, CORE, RUNS, TASK, fsdb_cli

def run(name):
    source = BASE / RUNS[name]
    line = next(s for s in (source/'simv.log').read_text().splitlines() if s.startswith('GEMM_LATENCY_DONE '))
    meta = dict(re.findall(r'(\w+)=([^\s]+)', line))
    first, end = int(meta['e_cfg']), int(meta['e_valid'])
    times = np.arange(first, end + 1, dtype=np.int64) * 10000 + 5000
    out = TASK/'captures'/name/'memory'
    out.mkdir(parents=True, exist_ok=True)
    prefix = CORE + ('/accel_perf.cpu_dma.' if name.startswith('naive') else '/accel_perf.hbm_dma.aggregate.')
    keys = ['rd_bytes','wr_bytes','xfer_count','active_cycles','src_rd_req_fire','src_rd_req_stall',
            'src_rd_data_fire','src_rd_data_stall','dst_wr_fire','dst_wr_stall','wait_dcache','wait_lmem','busy']
    paths = {k:prefix+k for k in keys}
    if name.startswith('naive'):
        for k in ['per_bank_req_valid','per_bank_req_ready','per_bank_req_rw']:
            paths[k] = CORE+'/mem_unit/local_mem/'+k
    data = {}
    unknown = {}
    for key,path in paths.items():
        cache = out/(key+'.npz')
        if cache.exists() and not key.startswith('per_bank_'):
            a=np.load(cache); t,v=a['t'],a['v']
        else:
            r=fsdb_cli.report(str(source/'wave.fsdb'),[path])
            assert r.data_rows,path
            t=np.array([int(x[0]) for x in r.data_rows],dtype=np.int64)
            v=np.array([int(re.sub('[xXzZ]', '0', x[1]),2) for x in r.data_rows],dtype=np.int64)
            u=np.array([int(''.join('0' if c in '01' else '1' for c in x[1]),2) for x in r.data_rows],dtype=np.int64)
            unknown[key]=u[np.searchsorted(t,times,side='left')-1]
            np.savez_compressed(cache,t=t,v=v)
        idx=np.searchsorted(t,times,side='left')-1
        assert np.all(idx>=0)
        data[key]=v[idx]
        assert np.all(data[key]>=0),key
    result={'name':name,'cycles':end-first,'counter_delta':{k:int(data[k][-1]-data[k][0]) for k in keys if k!='busy'},
            'external_union_busy':int(np.sum(data['busy'][:-1]==1))}
    if name.startswith('naive'):
        assert not np.any(unknown['per_bank_req_valid'])
        assert not np.any(unknown['per_bank_req_ready'] & data['per_bank_req_valid'])
        fire=(data['per_bank_req_valid'] & data['per_bank_req_ready'])[:-1]
        result['bank_words']=sum(int(v).bit_count() for v in fire)
        result['bank_utilization']=result['bank_words']/(16*(end-first))
        result['bank_accepted_by_index']=[int(np.sum((fire & (1<<i))!=0)) for i in range(16)]
        idle=(data['busy'][:-1]==0)
        result['external_idle_cycles']=int(np.sum(idle))
        result['bank_words_external_idle']=sum(int(v).bit_count() for v in fire[idle])
    np.savez_compressed(out/'samples.npz',**data)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)

if __name__=='__main__':
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(run,sys.argv[1:] or RUNS))
