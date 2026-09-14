"""Extract pre-edge M256 Input DMA signals and reproducible cycle annotations."""
from pathlib import Path
import sys
import json
import re
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

OUT = Path(__file__).resolve().parent / 'captures'
OUT.mkdir(exist_ok=True)
RUN = ROOT / 'agent-tasks/naive-psum-read-priority/runs/v2/r1-m256'
OLD = ROOT / 'agent-tasks/naive-psum-read-priority/captures/v2/r1-m256'
CORE = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
EX = CORE + '/gemm_node_naive/input_executor'
times = np.arange(26340, 600790, dtype=np.int64) * 10000 + 5000

def sample(name, path=None, old=False):
    cache = (OLD if old else OUT) / (name + '.npz')
    if not cache.exists():
        report = fsdb_cli.report(str(RUN / 'wave.fsdb'), [path])
        assert report.data_rows and report.time_unit == '1ps', path
        t = np.array([int(r[0]) for r in report.data_rows], dtype=np.int64)
        v = np.array([int(r[1], 2) if re.fullmatch('[01]+', r[1]) else -1
                      for r in report.data_rows], dtype=np.int64)
        np.savez_compressed(cache, t=t, v=v)
    a = np.load(cache)
    idx = np.searchsorted(a['t'], times, side='left') - 1
    assert np.all(idx >= 0)
    v = a['v'][idx]
    assert np.all(v >= 0), name
    return v

s = {k: sample(k, old=True) for k in ['req_valid', 'req_ready', 'input_fire', 'dma_busy']}
paths = {k: EX + '/' + k for k in ['data_valid', 'data_ready', 'cmd_valid', 'cmd_ready', 'dma_commands', 'dma_slots']}
paths.update({k: EX + '/contexts/' + k for k in ['admission_valid', 'output_available']})
paths.update({k: EX + '/source_dma/' + k for k in ['allocate', 'fetch_active_r', 'request_done', 'request_fire', 'sent_r', 'free_found', 'stage_valid_r', 'drain_found', 'load_stage', 'writer_released_r', 'install_last_o', 'install_segment_o', 'install_id_o', 'request_byte_addr']})
for k, p in paths.items():
    s[k] = sample(k, p)
    print(k, 'extracted', flush=True)
np.savez_compressed(OUT / 'sampled.npz', **s)
counts = {k: int(np.count_nonzero(v)) for k, v in s.items()}
no = s['req_valid'] == 0
counts.update({
    'no_valid': int(no.sum()),
    'no_valid_dma_idle': int((no & (s['dma_busy'] == 0)).sum()),
    'no_valid_no_admission': int((no & (s['admission_valid'] == 0)).sum()),
    'no_valid_admission_output_wait': int((no & (s['admission_valid'] == 1) & (s['output_available'] == 0)).sum()),
    'no_valid_admitted_no_data': int((no & (s['admission_valid'] == 1) & (s['output_available'] == 1) & (s['data_valid'] == 0)).sum()),
    'fetch_wait': int(((s['fetch_active_r'] == 1) & (s['request_done'] == 0)).sum()),
    'allocation_dma_idle': int(((s['allocate'] == 1) & (s['dma_busy'] == 0)).sum()),
})
(OUT / 'counts.json').write_text(json.dumps(counts, indent=2) + '\n')
print(json.dumps(counts, indent=2))
