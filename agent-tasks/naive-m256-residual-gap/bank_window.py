"""Export a bounded local LMEM contention window using fsdb_cli."""
from pathlib import Path
import sys
import csv
import json
import numpy as np
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli
OUT = Path(__file__).resolve().parent / 'captures'
RUN = ROOT / 'agent-tasks/naive-psum-read-priority/runs/v2/r1-m256'
CORE = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
EX = CORE + '/gemm_node_naive/input_executor/source_dma'
BANK = CORE + '/mem_unit/local_mem/g_naive_psum_priority/req_xbar/g_bank[4]'
paths = {f'lane{i}_ready': EX + f'/lane_bus_if[{i}]/req_ready' for i in range(4)}
paths.update({k: BANK + '/' + k for k in ['root_valid', 'root_read', 'root_write', 'selected', 'grant_fire']})
report = fsdb_cli.report(str(RUN / 'wave.fsdb'), list(paths.values()), bt='303600ns', et='304300ns')
assert report.time_unit == '1ps' and len(report.signal_names) == len(paths)
events = report.events()
et = np.array([e.time for e in events], dtype=np.int64)
s = dict(np.load(OUT / 'sampled.npz'))
keys = ['allocate', 'fetch_active_r', 'request_done', 'request_fire', 'sent_r', 'request_byte_addr', 'dma_busy', 'dma_slots', 'req_valid', 'req_ready']
rows = []
for cycle in range(30370, 30425):
    e = events[np.searchsorted(et, cycle * 10000 + 5000, side='left') - 1]
    row = {'cycle': cycle}
    row.update({k: int(e.values[sig], 2) for k, sig in zip(paths, report.signal_names)})
    row.update({k: int(s[k][cycle - 26340]) for k in keys})
    rows.append(row)
with (OUT / 'bank4_window.csv').open('w') as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
(OUT / 'bank4_paths.json').write_text(json.dumps(paths, indent=2) + '\n')
for r in rows:
    if 30387 <= r['cycle'] <= 30403:
        print(r)
