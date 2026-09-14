#!/usr/bin/env python3
"""Check ACC copy traffic and STORE ordering from pre-edge FSDB samples."""
from functools import lru_cache
import json
from pathlib import Path
import re
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

run = Path(sys.argv[1]).resolve()
result = json.loads((run / 'result.json').read_text())
assert result['passed'] and result['mode'] in ['on', 'off']
wave = str(run / 'wave.fsdb')
observer = re.search(r'^GEMM_LATENCY_DONE .*', (run / 'simv.log').read_text(), re.M)[0]
end = int(re.search(r'e_hs=(\d+)', observer)[1])
cycles = np.arange(1, end + 1)
times = cycles * 10000 + 5000
core = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
node = core + '/gemm_node_naive'


@lru_cache(maxsize=None)
def sample(relative, popcount=False):
    path = node + '/' + relative
    response = fsdb_cli.report(wave, [path])
    assert response.time_unit == '1ps' and response.data_rows, path
    t = np.array([int(row[0]) for row in response.data_rows], dtype=np.int64)
    states = {name: i for i, name in enumerate(['S_IDLE', 'S_DECODE', 'S_ALLOC_REQ',
              'S_ALLOC_R_WAIT', 'S_ALLOC_WAIT_GAP', 'S_PROG_W', 'S_KICK_W',
              'S_POLL_GAP', 'S_POLL_R_REQ', 'S_POLL_R_WAIT', 'S_DONE',
              'S_OUTPUT_START', 'S_OUTPUT_WAIT', 'S_OUTPUT_DRAIN'])}
    v = np.array([states[row[1]] if row[1] in states else -1 if re.search('[xXzZ]', row[1]) else
                  row[1].count('1') if popcount else int(row[1], 2)
                  for row in response.data_rows], dtype=np.int64)
    return v[np.maximum(0, np.searchsorted(t, times, side='left') - 1)]


def fires(bus):
    return (sample(bus + '/req_valid') == 1) & (sample(bus + '/req_ready') == 1)


final = fires('final_raw_bus_if')
final_stalls = (sample('final_raw_bus_if/req_valid') == 1) & (sample('final_raw_bus_if/req_ready') == 0)
out = dict(mode=result['mode'], case=result['case'], sample='Immediately before each 100MHz rising edge through GEMM completion',
           final_lmem_writes=int(final.sum()), final_lmem_write_bytes=int(final.sum()) * 32,
           final_lmem_stall_cycles=int(final_stalls.sum()))
if result['mode'] == 'off':
    out['psum_lmem_reads'] = int(fires('psum_rd_raw_bus_if').sum())
    out['psum_lmem_writes'] = int(fires('psum_wr_raw_bus_if').sum())
else:
    starts = sample('o_dma_ctrl_if/start') == 1
    done = sample('o_dma_ctrl_if/done') == 1
    drain = sample('gemm_write_queues_empty') == 1
    state = sample('dma_executor/state_q')
    # State ordering is preserved by appending ACC states after S_DONE:
    # S_ALLOC_REQ=2, S_OUTPUT_START=11, S_OUTPUT_WAIT=12, S_OUTPUT_DRAIN=13.
    alloc = (state == 2) & (np.roll(state, 1) == 13)
    assert starts.sum() == done.sum() == alloc.sum() > 0
    assert np.all(drain[np.maximum(0, np.flatnonzero(alloc) - 1)])
    assert np.all((sample('o_dma_ctrl_if/idle') == 1)[np.maximum(0, np.flatnonzero(alloc) - 1)])
    windows = []
    for start, finish, launch in zip(np.flatnonzero(starts), np.flatnonzero(done), np.flatnonzero(alloc)):
        assert start < finish < launch
        assert final[start:finish + 1].any()
        windows.append(dict(start_cycle=int(cycles[start]), dma_done_cycle=int(cycles[finish]),
                            hbm_allocate_cycle=int(cycles[launch]), copy_cycles=int(finish-start),
                            copy_and_drain_cycles=int(launch-start)))
    out['copies'] = windows
    out['copy_cycles'] = sum(w['copy_cycles'] for w in windows)
    out['copy_and_drain_cycles'] = sum(w['copy_and_drain_cycles'] for w in windows)
    wr = (sample('gemm_acc_if/wr_req_valid') == 1) & (sample('gemm_acc_if/wr_req_ready') == 1)
    out['acc_writes'] = int(wr.sum())
    out['acc_final_writes'] = int((wr & (sample('gemm_acc_if/wr_req_final_output') == 1)).sum())
    out['acc_sram_writes'] = int(sample('u_acc_internal/acc_mem_wr_en', True).clip(min=0).sum())
    assert out['acc_writes'] == out['acc_sram_writes']
    assert out['acc_final_writes'] == out['final_lmem_writes']
    out['acc_output_reads'] = int(fires('o_gemm_bus_if').sum())
    assert out['acc_output_reads'] == out['final_lmem_writes']
    read_requests = 0
    psum_writes = 0
    for lane in range(32):
        read_requests += int((sample(f'psum_rd_lmem_bus_if[{lane}]/req_valid') == 1).sum())
        bus = f'psum_wr_lmem_bus_if[{lane}]'
        requests = sample(bus + '/req_valid') == 1
        marked = (sample(bus + '/req_data.flags') & 1) != 0
        psum_writes += int((requests & marked).sum())
    assert read_requests == psum_writes == 0
    out.update(psum_lmem_reads=read_requests, psum_lmem_writes=psum_writes,
               store_after_physical_drain=True)
(run / 'analysis.json').write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out, indent=2))
