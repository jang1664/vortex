#!/usr/bin/env python3
"""Read FSDB through fsdb_cli; sample stable pre-edge handshakes per cycle."""
from bisect import bisect_right
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
TASK = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli as fsdb

AXI = '/tb_vcs_xrtsim/dut/vortex_axi'
CORE = AXI + '/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
NODE = CORE + '/gemm_node'
CTRL = NODE + '/u_VX_gemm_ctrl'
TMEM = NODE + '/u_tmem_subsystem'
UNIT = NODE + '/u_VX_gemm_unit_v2/u_compute_core'

def integer(value):
    value = value.strip().lower()
    if not value or any(c in value for c in 'xz'):
        return None
    return int(value, 2)

def read_signal(wave, path, bt=None, et=None):
    rep = fsdb.report(str(wave), [path], bt=bt, et=et)
    if len(rep.signal_names) != 1 or rep.time_unit != '1ps' or not rep.data_rows:
        raise RuntimeError(f'Missing/invalid signal {path}: {rep.signal_names}')
    rows = [(int(r[0]), integer(r[1])) for r in rep.data_rows if len(r) > 1 and r[1].strip()]
    return rows

def signals(channels):
    result = {'invocation': CTRL+'/invocation_active_q', 'computing': CTRL+'/gemm_unit_computing',
              'total': CTRL+'/perf_total_cycles_r', 'any_dma': CORE+'/any_dma_busy',
              'hbm_busy': TMEM+'/u_dma_engine/aggregate_busy', 'clk': '/tb_vcs_xrtsim/ap_clk'}
    for name in ['input_fire', 'compute_fire', 'mxu_ready_weight', 'weight_ready', 'zero_ready',
                 'compute_ready', 'prealigner_out_valid', 'pre_meta_valid_out', 'tree_credit_q',
                 'sc_req_hs', 'zp_req_hs']:
        result[name] = UNIT+'/'+name
    for bus in ['i','w','sc','zp','o']:
        for sig in ['req_valid','req_ready']:
            result[f'gemm_{bus}_{sig}'] = NODE+f'/{bus}_gemm_bus_if/{sig}'
    for port in range(channels):
        for sig in ['ar_valid','ar_ready','ar_len','ar_addr','r_valid','r_ready',
                    'aw_valid','aw_ready','aw_len','w_valid','w_ready','b_valid','b_ready']:
            result[f'axi{port}_{sig}'] = AXI+f'/dma_axi_m[{port}]/{sig}'
        for sig in ['sram_read','sram_write','request_valid','request_ready']:
            result[f'bank{port}_{sig}'] = TMEM+f'/g_bank[{port}]/u_bank/{sig}'
        result[f'dma{port}_cfg_fire'] = TMEM+f'/u_dma_engine/g_channel[{port}]/cfg_fire'
    for name, bus in [('i','ldma_to_switch[0]'),('w','ldma_weight_to_tmem'),
                      ('sc','ldma_to_switch[2]'),('zp','ldma_to_switch[3]'),('o','ldma_to_switch[4]')]:
        for sig in ['req_valid','req_ready','rsp_valid','rsp_ready']:
            result[f'ldma_{name}_{sig}'] = TMEM+'/'+bus+'/'+sig
    for sig in ['queue_cmd_occupancy', 'queue_slot_occupancy', 'queue_ready_ahead',
                'command_enqueue', 'writer_released', 'command_total_beats']:
        result['weight_'+sig] = TMEM+'/u_ldma_weight/'+sig
    return result

def extract(channels,m):
    case = TASK/f'ch{channels}'/f'm{m}'
    wave = case/'vcs_cosim.fsdb'
    out = case/'signals'
    out.mkdir(exist_ok=True)
    inv = read_signal(wave, CTRL+'/invocation_active_q')
    rises = [t for t,v in inv if v==1]
    assert len(rises)==1, inv
    start = rises[0]
    end = next(t for t,v in inv if t>start and v==0)
    period = 10000
    assert (end-start)%period==0
    times = list(range(start+period//2,end,period))
    paths = signals(channels)
    def load(item):
        key,path = item
        cache = out/f'{key}.json'
        if cache.exists():
            stored = json.loads(cache.read_text())
            assert stored['path']==path
            rows=stored['rows']
        else:
            rows=read_signal(wave,path,bt=f'{start-30000}ps',et=f'{end+30000}ps')
            cache.write_text(json.dumps({'path':path,'rows':rows})+'\n')
        ts=[r[0] for r in rows]
        values=[rows[bisect_right(ts,t)-1][1] for t in times]
        assert all(bisect_right(ts,t)>0 for t in times)
        return key,values
    print(f'EXTRACT ch{channels} M{m}: {len(paths)} signals, {len(times)} cycles',flush=True)
    with ThreadPoolExecutor(max_workers=12) as pool:
        data=dict(pool.map(load,paths.items()))
    expected=json.loads((case/'result.json').read_text())['metrics']['total_cycles']
    assert len(times)==expected,(len(times),expected)
    assert all(v==1 for v in data['invocation'])
    assert all(v==0 for v in data['clk']), 'Samples must be stable falling-clock values'
    # Counter advances once per cycle: at each falling edge its value is the
    # number of prior accepted cycles; next posedge consumes the sampled state.
    assert data['total']==list(range(expected)),data['total'][:8]
    (case/'sampled.json').write_text(json.dumps({'start_ps':start,'end_ps':end,'period_ps':period,
        'cycles':len(times),'channels':channels,'M':m,'data':data})+'\n')
    print(f'DONE ch{channels} M{m}',flush=True)

if __name__=='__main__':
    for channels in [8,4]:
        for m in [1,4]:
            extract(channels,m)
