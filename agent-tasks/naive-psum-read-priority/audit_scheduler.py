"""Audit observed per-bank quota service and write metadata occupancy in FSDB."""
import argparse
import json
from pathlib import Path
import re
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('run', type=Path)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--banks', type=int, nargs='+', default=list(range(16)))
a = p.parse_args()
run, out = a.run.resolve(), a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
result = json.loads((run / 'result.json').read_text())
assert result['passed']
quota = result['read_quota']
meta = dict(re.findall(r'(\w+)=([^\s]+)', result['observer_done'][0]))
begin, end = int(meta['e_cfg']), int(meta['e_valid'])
times = np.arange(begin, end + 1, dtype=np.int64) * 10000 + 5000
core = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'

def sample(key, path):
    cache = out / (key + '.npz')
    if cache.exists():
        saved = np.load(cache)
        t, v = saved['t'], saved['v']
    else:
        report = fsdb_cli.report(str(run / 'wave.fsdb'), [path])
        assert report.time_unit == '1ps' and report.data_rows, path
        t = np.array([int(row[0]) for row in report.data_rows], dtype=np.int64)
        v = np.array([int(row[1], 2) if re.fullmatch('[01]+', row[1]) else -1
                      for row in report.data_rows], dtype=np.int64)
        np.savez_compressed(cache, t=t, v=v)
    idx = np.searchsorted(t, times, side='left') - 1
    assert np.all(idx >= 0)
    values = v[idx]
    assert np.all(values >= 0), path
    return values

node = core + '/gemm_node_naive'
valid = sample('psum_write_valid', node + '/psum_write_valid')
occupancy = np.array([int(v).bit_count() for v in valid])
assert occupancy[-1] == 0, 'Write metadata not empty at GEMM completion'
banks = []
for bank in a.banks:
    assert 0 <= bank < 16
    path = core + f'/mem_unit/local_mem/g_naive_psum_priority/req_xbar/g_bank[{bank}]'
    signals = {key: sample(f'bank{bank}_{key}', path + '/' + key)
               for key in ['root_valid', 'root_read', 'root_write', 'selected_root',
                           'grant_fire', 'locked', 'read_streak']}
    valid = signals['root_valid'][:-1]
    reads = signals['root_read'][:-1]
    writes = signals['root_write'][:-1]
    read_waiting = (valid & reads) != 0
    write_waiting = (valid & writes) != 0
    selected_bit = np.left_shift(1, signals['selected_root'][:-1])
    grant = signals['grant_fire'][:-1] == 1
    read_grant = grant & ((reads & selected_bit) != 0)
    write_grant = grant & ((writes & selected_bit) != 0)
    streak = signals['read_streak'][:-1]
    locked = signals['locked'][:-1] == 1
    # A locked choice predates current contention and cannot be retracted.
    violation = read_grant & write_waiting & (streak >= quota) & ~locked
    assert not np.any(violation), (bank, (np.flatnonzero(violation) + begin).tolist()[:10])
    assert signals['read_streak'].max() <= quota
    contention = read_waiting & write_waiting
    def examples(mask):
        return (np.flatnonzero(mask)[:8] + begin).tolist()
    banks.append(dict(bank=bank, contention_cycles=int(contention.sum()),
        read_grants=int(read_grant.sum()), write_grants=int(write_grant.sum()),
        read_grants_with_write_waiting=int((read_grant & write_waiting).sum()),
        quota_write_grants=int((write_grant & (streak >= quota)).sum()),
        max_read_streak=int(signals['read_streak'].max()),
        contention_read_examples=examples(contention & read_grant),
        quota_write_examples=examples(write_grant & (streak >= quota))))
report = dict(run=str(run.relative_to(ROOT)), read_quota=quota,
              max_write_metadata_occupancy=int(occupancy.max()),
              write_metadata_empty_at_done=True, banks=banks,
              sampling='Strict preedge, risingedge at cycle*10ns+5ns; quota applies at buffered root.')
(out / 'scheduler.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report), flush=True)
