"""Measure Input request rollover, handshake integrity and additive GEMM phases."""
from pathlib import Path
import argparse
import csv
import json
import re
import sys
import numpy as np

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
sys.path.insert(0, str(ROOT/'tools'))
import fsdb_cli

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('case', choices=['m4', 'm256'])
args = ap.parse_args()
run = TASK/'runs/v1'/args.case
out = TASK/'captures'/args.case
out.mkdir(parents=True, exist_ok=True)
manifest = json.loads((run/'manifest.json').read_text())
assert manifest['passed'] and not manifest['source_changes_during_run']
done = [x for x in (run/'simv.log').read_text().splitlines() if x.startswith('GEMM_LATENCY_DONE ')]
assert len(done) == 1
meta = dict(re.findall(r'(\w+)=([^\s]+)', done[0]))
cfg, end, store = (int(meta[k]) for k in ['e_cfg', 'e_valid', 'e_store'])
cycles = np.arange(cfg, end+1, dtype=np.int64)
times = cycles*10000+5000
core = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
compute = core+'/gemm_node_naive/u_VX_gemm_compute_core'
dma = core+'/gemm_node_naive/input_executor/source_dma'

def sample(key, path):
    cache = out/(key+'.npz')
    if not cache.exists():
        report = fsdb_cli.report(str(run/'wave.fsdb'), [path])
        assert report.data_rows and report.time_unit == '1ps', path
        t = np.array([int(r[0]) for r in report.data_rows], dtype=np.int64)
        v = np.array([int(r[1], 2) if re.fullmatch('[01]+', r[1]) else -1
                      for r in report.data_rows], dtype=np.int64)
        np.savez_compressed(cache, t=t, v=v)
    z = np.load(cache)
    idx = np.searchsorted(z['t'], times, side='left')-1
    assert np.all(idx >= 0), path
    v = z['v'][idx]
    assert np.all(v >= 0), path
    print(key, 'sampled', flush=True)
    return v

s = {k: sample(k, compute+'/'+k) for k in ['input_fire', 'acc_write_fire',
     'prealigner_out_valid', 'weight_ready', 'post_txn_count', 'post_head_psum_ready',
     'post_head_scaled_ready']}
s.update({k: sample(k, compute+'/input_bus_if/'+k) for k in ['req_valid','req_ready']})
for k in ['allocate', 'request_done', 'fetch_active_r', 'free_found', 'request_fire',
          'sent_r', 'fetch_slot_r', 'request_byte_addr', 'allocate_owner', 'allocate_segment',
          'valid_r', 'slot_occupancy_o', 'install_segment_o', 'install_id_o']:
    s[k] = sample(k, dma+'/'+k)
expected = manifest['m']*manifest['k']*manifest['n']//256
ie = cycles[s['input_fire']==1]; ae = cycles[s['acc_write_fire']==1]
rd = s['request_done']==1; al = s['allocate']==1; active=s['fetch_active_r']==1
assert len(ie)==len(ae)==int(rd.sum())==int(al.sum())==expected
rows = min(manifest['m'],128)
input_mask = s['input_fire']==1
assert np.array_equal(s['install_segment_o'][input_mask], np.tile(np.arange(rows), expected//rows))
assert np.array_equal(s['install_id_o'][input_mask], np.repeat(np.arange(1,expected//rows+1), rows))
assert np.all((s['request_fire'] & s['sent_r'])==0), 'Lane request duplicated'
assert all(int(((s['request_fire']>>lane)&1).sum())==expected for lane in range(4))
stalled = active[:-1] & ~rd[:-1]
assert np.all(s['fetch_active_r'][1:][stalled]==1)
for k in ['fetch_slot_r', 'request_byte_addr']:
    assert np.all(s[k][1:][stalled]==s[k][:-1][stalled]), k+' changed while stalled'
assert np.all(s['sent_r'][1:][stalled] == (s['sent_r'][:-1]|s['request_fire'][:-1])[stalled])
assert np.all(s['fetch_active_r'][1:][al[:-1]]==1)
assert np.all(s['sent_r'][1:][al[:-1]]==0)
eligible = rd & (s['free_found']==1) & (((s['valid_r']>>s['allocate_owner'])&1)==1) & (s['allocate_segment']<min(manifest['m'],128))
assert np.all(al[eligible]), 'Eligible replacement missed'
assert np.any(rd[:-1]&rd[1:]), 'No consecutive row request completions observed'
boundaries = [cfg,int(ie[0]),int(ie[-1]),int(ae[-1]),store,end]
assert all(y>=x for x,y in zip(boundaries,boundaries[1:]))
phases = dict(zip(['startup','input_stream','compute_drain','output_tail','finalize'],map(int,np.diff(boundaries))))
assert sum(phases.values())==end-cfg
stream=(cycles>=ie[0])&(cycles<ie[-1])
activity={
    'input_fire': int(((s['req_valid']==1)&(s['req_ready']==1)&stream).sum()),
    'input_backpressure': int(((s['req_valid']==1)&(s['req_ready']==0)&stream).sum()),
    'input_no_supply': int(((s['req_valid']==0)&stream).sum()),
}
assert sum(activity.values())==phases['input_stream']
part={
    'allocation_only': al & ~rd,
    'request_complete_with_replacement': rd & al,
    'request_complete_without_replacement': rd & ~al,
    'request_wait': active & ~rd,
    'inactive_full': ~active & ~al & (s['free_found']==0),
    'inactive_free': ~active & ~al & (s['free_found']==1),
}
assert np.all(sum(v.astype(int) for v in part.values())==1)
edges=cycles[rd & stream]
iv,ct=np.unique(np.diff(edges),return_counts=True)
result=dict(case=args.case,gemm_cycles=end-cfg,input_count=expected,
            boundaries=dict(zip(['cfg','first_input','last_input','last_acc_write','store','done'],boundaries)),
            phases=phases,input_activity=activity,
            source_partition={k:int((v&stream).sum()) for k,v in part.items()},
            request_intervals=dict(zip(map(str,iv),map(int,ct))),
            rollover_total=int((al&rd).sum()),
            command_rollover_total=int((al&rd&(s['allocate_segment']==0)).sum()),
            max_input_slots=int(s['slot_occupancy_o'].max()),
            partial_lane_wait_cycles=int((stalled&(s['sent_r'][:-1]!=0)).sum()),
            eligible_replacements=int(eligible.sum()),handshake_checks='pass')
weight_wait = (s['prealigner_out_valid']==1)&(s['weight_ready']==0)
psum_wait = (s['post_txn_count']!=0)&(s['post_head_psum_ready']==0)
bp = (s['req_valid']==1)&(s['req_ready']==0)
result['overlapping_stalls'] = {
    'weight_wait': int((weight_wait&stream).sum()),
    'psum_wait': int((psum_wait&stream).sum()),
    'psum_only_wait': int((psum_wait&(s['post_head_scaled_ready']==1)&stream).sum()),
    'bp_weight_only': int((bp&weight_wait&~psum_wait&stream).sum()),
    'bp_psum_only': int((bp&psum_wait&~weight_wait&stream).sum()),
    'bp_both': int((bp&psum_wait&weight_wait&stream).sum()),
    'bp_neither': int((bp&~psum_wait&~weight_wait&stream).sum()),
}
np.savez_compressed(out/'sampled.npz', cycles=cycles, **s)
(TASK/(args.case+'-analysis.json')).write_text(json.dumps(result,indent=2)+'\n')
# Choose a real continuous request window; separately annotate a command boundary.
windows={}
for key, mask in [('continuous', np.convolve(rd.astype(int),np.ones(8,dtype=int),'valid')==8),
                  ('command', al&rd&(s['allocate_segment']==0))]:
    ids=np.flatnonzero(mask)
    if len(ids):windows[key]=range(max(0,int(ids[0])-2),min(len(cycles),int(ids[0])+10))
wait_mask = bp & psum_wait & ~weight_wait & stream
change = np.diff(np.r_[False,wait_mask,False].astype(int))
starts,ends = np.flatnonzero(change==1),np.flatnonzero(change==-1)
if len(starts):
    longest = int(np.argmax(ends-starts))
    result['psum_backpressure_window'] = [int(cycles[starts[longest]]),int(cycles[ends[longest]-1])+1]
    windows['psum-backpressure'] = range(max(0,int(starts[longest])-2),min(len(cycles),int(starts[longest])+12))
fields=['cycle','allocate','request_done','fetch_active_r','request_fire','sent_r',
        'fetch_slot_r','request_byte_addr','allocate_owner','allocate_segment',
        'slot_occupancy_o','req_valid','req_ready','input_fire','weight_ready',
        'post_txn_count','post_head_psum_ready','post_head_scaled_ready']
for name, indexes in windows.items():
    with (TASK/(args.case+'-'+name+'.csv')).open('w') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for i in indexes:w.writerow({'cycle':int(cycles[i]),**{k:int(s[k][i]) for k in fields[1:]}})
(TASK/(args.case+'-analysis.json')).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
