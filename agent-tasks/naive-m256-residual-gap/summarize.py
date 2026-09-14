"""Produce audited statistics and small reviewable cycle tables from captures."""
from pathlib import Path
import csv
import hashlib
import json
import numpy as np

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[1]
CAP = TASK / 'captures'
s = dict(np.load(CAP / 'sampled.npz'))
cycles = np.arange(26340, 600790)
a, f, d = (s[k] == 1 for k in ['allocate', 'fetch_active_r', 'request_done'])
idle = ~f & ~a
masks = {'allocation_only': a, 'request_complete': d,
         'request_wait': f & ~d,
         'inactive_full': idle & (s['free_found'] == 0),
         'inactive_free': idle & (s['free_found'] == 1)}
assert np.all(sum(m.astype(int) for m in masks.values()) == 1)
result = {'source_partition': {k: int(v.sum()) for k, v in masks.items()}}
result['input_partition'] = {
    'fire': int(((s['req_valid'] == 1) & (s['req_ready'] == 1)).sum()),
    'backpressure': int(((s['req_valid'] == 1) & (s['req_ready'] == 0)).sum()),
    'no_valid_output_wait': int(((s['req_valid'] == 0) & (s['output_available'] == 0)).sum()),
    'no_valid_source_empty': int(((s['req_valid'] == 0) & (s['output_available'] == 1) & (s['data_valid'] == 0)).sum())}
assert sum(result['input_partition'].values()) == len(cycles)
assert np.all(s['admission_valid'] == 1)
assert np.array_equal(s['data_valid'], s['stage_valid_r'])
result['overlapping_conditions'] = {
    'no_valid_external_dma_idle': int(((s['req_valid'] == 0) & (s['dma_busy'] == 0)).sum()),
    'request_wait_external_dma_idle': int((masks['request_wait'] & (s['dma_busy'] == 0)).sum()),
    'allocation_external_dma_idle': int((a & (s['dma_busy'] == 0)).sum()),
    'inactive_full_output_wait': int((masks['inactive_full'] & (s['output_available'] == 0)).sum())}
edges = cycles[d]
v, n = np.unique(np.diff(edges), return_counts=True)
assert min(v) == 2
result['naive_request_intervals'] = dict(zip(map(str, v), map(int, n)))
result['improve_requests'] = json.loads((CAP / 'improve_counts.json').read_text())
changes = np.diff(np.r_[False, s['output_available'] == 0, False].astype(int))
result['output_wait_intervals'] = [[int(cycles[x]), int(cycles[y-1]) + 1]
    for x, y in zip(np.flatnonzero(changes == 1), np.flatnonzero(changes == -1))]

def cached_sample(path, c):
    z = np.load(path)
    idx = np.searchsorted(z['t'], c * 10000 + 5000, side='left') - 1
    assert np.all(idx >= 0)
    data = z['v'][idx]
    assert np.all(data >= 0)
    return data

OLD = ROOT / 'agent-tasks/naive-psum-read-priority/captures/v2/r1-m256'
full_cycles = np.arange(24758, 601521)
for p in ['psum_rd_wide', 'psum_wr_raw']:
    valid = cached_sample(OLD / (p + '_valid.npz'), full_cycles)
    ready = cached_sample(OLD / (p + '_ready.npz'), full_cycles)
    e = full_cycles[(valid == 1) & (ready == 1)]
    result[p] = {'fires': len(e), 'first': int(e[0]), 'last': int(e[-1])}
result['minimum_local_bytes_input_and_psum'] = 262144 * 32 + 2 * 253952 * 64
result['ideal_128_bytes_per_cycle_lower_bound'] = result['minimum_local_bytes_input_and_psum'] // 128

def export(name, rows):
    with (TASK / name).open('w') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

keys = ['allocate', 'fetch_active_r', 'request_done', 'request_fire', 'request_byte_addr',
        'dma_slots', 'data_valid', 'req_ready', 'input_fire', 'dma_busy']
export('naive_issue_window.csv', [{'cycle': c, **{k: int(s[k][c-26340]) for k in keys}}
                                for c in range(30321, 30337)])
im = dict(np.load(CAP / 'improve_sampled.npz'))
ic = np.arange(30000, 30016)
ibase = ROOT / 'agent-tasks/dma-read-slot-saturation/captures/improve16-m256'
ivals = {k: cached_sample(ibase / (k + '.npz'), ic) for k in ['req_valid', 'req_ready', 'input_fire']}
export('improve_issue_window.csv', [{'cycle': int(c),
    **{k: int(im[k][c-26921]) for k in im},
    **{k: int(ivals[k][i]) for k in ivals}} for i, c in enumerate(ic)])
with (CAP / 'bank4_window.csv').open() as f:
    rows = list(csv.DictReader(f))
export('naive_bank4_window.csv', rows)

result['rtl_hash_checks'] = {}
for run, files in [
    ('agent-tasks/naive-psum-read-priority/runs/v2/r1-m256', [
     'hw/rtl/core/gemm/VX_naive_input_executor.sv', 'hw/rtl/core/gemm/VX_naive_input_contexts.sv',
     'hw/rtl/core/gemm/VX_naive_qparam_dma.sv', 'hw/rtl/core/gemm/VX_gemm_acc_lmem.sv', 'hw/rtl/mem/VX_local_mem.sv']),
    ('agent-tasks/dma-read-slot-saturation/improve/runs/depth16-m256', [
     'hw/rtl/core/gemm/VX_lmem_dma_misal.sv', 'hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv',
     'hw/rtl/mem/VX_tmem_subsystem.sv', 'hw/rtl/core/gemm/VX_gemm_acc_internal.sv'])]:
    manifest = json.loads((ROOT / run / 'manifest.json').read_text())
    for path in files:
        actual = hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        assert actual == manifest['source_hashes'][path], path
        result['rtl_hash_checks'][path] = actual
(TASK / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
