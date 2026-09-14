"""Measure the improve local Input request interval from the reference FSDB."""
from pathlib import Path
import sys
import re
import json
import numpy as np
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli
OUT = Path(__file__).resolve().parent / 'captures'
OUT.mkdir(exist_ok=True)
RUN = ROOT / 'agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m256'
BASE = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input'
cycles = np.arange(26921, 297262, dtype=np.int64)
s = {}
for key, suffix in [('request', 'source_req_fire'), ('valid', 'lmem_bus_if/req_valid'), ('ready', 'lmem_bus_if/req_ready')]:
    cache = OUT / ('improve_' + key + '.npz')
    if not cache.exists():
        report = fsdb_cli.report(str(RUN / 'wave.fsdb'), [BASE + '/' + suffix])
        assert report.data_rows and report.time_unit == '1ps'
        t = np.array([int(r[0]) for r in report.data_rows], dtype=np.int64)
        v = np.array([int(r[1], 2) if re.fullmatch('[01]+', r[1]) else -1 for r in report.data_rows], dtype=np.int64)
        np.savez_compressed(cache, t=t, v=v)
    a = np.load(cache)
    s[key] = a['v'][np.searchsorted(a['t'], cycles * 10000 + 5000, side='left') - 1]
    assert np.all(s[key] >= 0)
    print(key, 'extracted', flush=True)
edges = cycles[s['request'] == 1]
intervals, counts = np.unique(np.diff(edges), return_counts=True)
result = {'intervals': dict(zip(map(str, intervals), map(int, counts))), 'requests': len(edges),
          'request_stall': int(((s['valid'] == 1) & (s['ready'] == 0)).sum())}
(OUT / 'improve_counts.json').write_text(json.dumps(result, indent=2) + '\n')
np.savez_compressed(OUT / 'improve_sampled.npz', **s)
print(json.dumps(result, indent=2))
