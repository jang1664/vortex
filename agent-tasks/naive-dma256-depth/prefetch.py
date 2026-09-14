#!/usr/bin/env python3
"""Batch FSDB signal extraction for analyze.py without changing shared tooling.

fsdbreport accepts multiple paths after ONE -s. Repeated -s keeps only the last
path. Save each signal's transitions in the analyzer's existing NPZ cache format.
"""
import concurrent.futures
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import numpy as np

run = Path(sys.argv[1])
r = json.loads((run / 'result.json').read_text())
assert r['passed'], 'Only analyze numerically verified performance candidates'
C = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
D = C + '/u_VX_dma_node/u_dma_unit/g_misaligned/u_impl'
A = '/tb_vcs_xrtsim/dut/vortex_axi'
ordered = '-DDMA_SPLIT_RSP_REORDER=1' in r['configs']
ports = 16 if r['variant'] == 'l16' else 32
paths = []
def add(path, pop=False):
    paths.append((path, pop))

for n in ['busy', 'rd_bytes', 'wr_bytes', 'active_cycles', 'src_rd_req_fire',
          'src_rd_req_stall', 'src_rd_data_fire', 'src_rd_data_stall',
          'dst_wr_fire', 'dst_wr_stall', 'wait_dcache', 'wait_lmem']:
    add(D + '/perf.' + n)
add(D + '/slot_occupancy_r')
splits = [(C + '/u_VX_dma_node/g_split_lmem_lanes/lmem_lane_split', ports)]
if r['variant'].startswith('d'):
    splits.append((C + '/mem_unit/g_split_dma_dcache_ports/dma_dcache_split', 4))
for path, lanes in splits:
    p = path + '/g_reorder_response/response_store'
    add(p + '/contexts/size' if ordered else path + '/g_masked_response/rsp_context_queue/size')
    add(path + '/rsp_ctx_full')
    for i in range(lanes):
        extra = 'g_fifo/' if r['variant'] == 'l32' else ''
        add(p + f'/g_lane[{i}]/received_r' if ordered else
            path + f'/g_lane_rsp[{i}]/' + extra + 'rsp_skid/g_ebN/fifo_queue/size', ordered)
    if ordered:
        for n in ['context_empty', 'all_complete', 'output_valid_r', 'response_ready']:
            add(p + '/' + n)
def bus(path):
    for n in ['req_valid', 'req_ready', 'req_data.rw', 'rsp_valid', 'rsp_ready']:
        add(path + '/' + n)
    add(path + '/req_data.byteen', True)
bus(C + '/dma_global_data_if')
for i in range(ports):
    bus(C + f'/dma_local_data_if[{i}]')
if r['variant'].startswith('d'):
    for i in range(4):
        bus(C + f'/mem_unit/dcache_dma_lane_if[{i}]')
for i in range(8):
    for n in ['rvalid', 'rready', 'wvalid', 'wready', 'arvalid', 'arready']:
        add(A + f'/m_axi_{n}[{i}]')
    add(A + f'/m_axi_wstrb[{i}]', True)
for n in ['reads', 'writes', 'read_misses', 'write_misses', 'mshr_stalls', 'crsp_stalls']:
    add(C.rsplit('/g_cores', 1)[0] + '/dcache_perf.' + n)

cache = run / 'samples'
cache.mkdir(exist_ok=True)
def dest(item):
    path, pop = item
    return cache / (path.replace('/', '__').replace('.', '_') + ('_pop' if pop else '') + '.npz')

missing = [p for p in paths if not dest(p).exists()]
def batch(job):
    index, items = job
    output = cache / f'batch_{index}.csv'
    cmd = ['fsdbreport', str(run / 'wave.fsdb'), '-s', *[p for p, _ in items],
           '-csv', '-o', str(output)]
    subprocess.run(cmd, env={**os.environ, 'LD_PRELOAD': '/usr/lib/x86_64-linux-gnu/libstdc++.so.6'},
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    ts = [[] for _ in items]
    vs = [[] for _ in items]
    with output.open() as f:
        reader = csv.reader(f)
        header = next(reader)
        assert header == ['Time(1ps)', *[p for p, _ in items]], header
        for row in reader:
            if not row:
                continue
            for i, (_, pop) in enumerate(items):
                value = row[i+1]
                if not value:
                    continue
                v = -1 if re.search('[xXzZ]', value) else value.count('1') if pop else int(value, 2)
                if not vs[i] or v != vs[i][-1]:
                    ts[i].append(int(row[0]))
                    vs[i].append(v)
    for i, item in enumerate(items):
        assert ts[i], item
        np.savez_compressed(dest(item), t=np.array(ts[i], dtype=np.int64), v=np.array(vs[i], dtype=np.int64))
    # Explicit temporary output, already converted and verified above.
    output.unlink()
    return len(items)

jobs = list(enumerate([missing[i:i+24] for i in range(0, len(missing), 24)]))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for n in pool.map(batch, jobs):
        print('Cached', n, 'signals', flush=True)
subprocess.run([sys.executable, str(Path(__file__).with_name('analyze.py')), str(run)], check=True)
