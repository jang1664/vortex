"""Measure additive GEMM phases and overlapping DMA activity from FSDB."""
import argparse
import json
from pathlib import Path
import re
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('run', type=Path)
ap.add_argument('--depth', type=int, required=True)
ap.add_argument('--out', type=Path, required=True)
args = ap.parse_args()
run = args.run.resolve()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
manifest = json.loads((run / 'manifest.json').read_text())
assert manifest['passed'] and not manifest['source_changes_during_run']
naive = manifest['backend'] == 'naive'
done = [s for s in (run / 'simv.log').read_text().splitlines()
        if s.startswith('GEMM_LATENCY_DONE ')]
assert len(done) == 1
meta = dict(re.findall(r'(\w+)=([^\s]+)', done[0]))
cfg, end, store = (int(meta[k]) for k in ['e_cfg', 'e_valid', 'e_store'])
times = np.arange(cfg, end + 1, dtype=np.int64) * 10000 + 5000
core = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
node = core + ('/gemm_node_naive' if naive else '/gemm_node')
compute = node + ('/u_VX_gemm_compute_core' if naive else '/u_VX_gemm_unit_v2/u_compute_core')

def sample(name, path):
    cache = out / (name + '.npz')
    if cache.exists():
        a = np.load(cache)
        t, v = a['t'], a['v']
    else:
        report = fsdb_cli.report(str(run / 'wave.fsdb'), [path])
        assert report.data_rows and report.time_unit == '1ps', path
        t = np.array([int(row[0]) for row in report.data_rows], dtype=np.int64)
        enum = {'RD_IDLE': 0, 'RD_RUN': 1, 'RD_DONE': 2}
        v = np.array([int(row[1], 2) if re.fullmatch('[01]+', row[1]) else enum.get(row[1], -1)
                      for row in report.data_rows], dtype=np.int64)
        np.savez_compressed(cache, t=t, v=v)
    idx = np.searchsorted(t, times, side='left') - 1
    assert np.all(idx >= 0), path
    data = v[idx]
    assert np.all(data >= 0), (path, int(np.sum(data < 0)))
    return data

s = {}
for key in ['input_fire', 'acc_write_fire', 'prealigner_out_valid',
            'pre_meta_valid_out', 'weight_ready', 'post_txn_count',
            'post_head_psum_ready', 'post_head_scaled_ready', 'compute_ready',
            'acc_result_credit', 'acc_result_commit']:
    s[key] = sample(key, compute + '/' + key)
for key in ['req_valid', 'req_ready']:
    s[key] = sample(key, compute + '/input_bus_if/' + key)
input_edges = np.flatnonzero(s['input_fire'][:-1] == 1) + cfg
acc_edges = np.flatnonzero(s['acc_write_fire'][:-1] == 1) + cfg
expected_inputs = manifest['m'] * manifest['k'] * manifest['n'] // (16 * 16)
assert len(input_edges) == expected_inputs
assert len(acc_edges) == expected_inputs
boundaries = [cfg, int(input_edges[0]), int(input_edges[-1]),
              int(acc_edges[-1]), store, end]
assert all(b >= a for a, b in zip(boundaries, boundaries[1:])), boundaries
phase_names = ['startup', 'input_stream', 'compute_drain', 'output_tail', 'finalize']
phases = dict(zip(phase_names, np.diff(boundaries).tolist()))
assert sum(phases.values()) == end - cfg

prefix = core + ('/accel_perf.cpu_dma.' if naive else '/accel_perf.hbm_dma.aggregate.')
counter_keys = ['rd_bytes', 'wr_bytes', 'xfer_count', 'active_cycles',
                'src_rd_req_fire', 'src_rd_req_stall', 'src_rd_data_fire',
                'src_rd_data_stall', 'dst_wr_fire', 'dst_wr_stall',
                'wait_dcache', 'wait_lmem']
counters = {key: sample('dma_' + key, prefix + key) for key in counter_keys}
busy = sample('dma_busy', prefix + 'busy')[:-1] == 1
units = ([core + '/u_VX_dma_node/u_dma_unit/g_misaligned/u_impl'] if naive else
         [node + f'/u_tmem_subsystem/u_dma_engine/g_channel[{ch}]/u_dma_unit/g_aligned/u_impl'
          for ch in range(8)])
read_busy = np.zeros(end-cfg, dtype=bool)
write_busy = read_busy.copy()
dma_units = []
for i, unit in enumerate(units):
    keys = ['slot_occupancy_r', 'dma_is_active', 'active_dir', 'rd_state']
    keys += ['rd_src_ptr_r', 'rd_src_end_r'] if naive else ['source_issue_enable']
    data = {key: sample(f'unit{i}_{key}', unit + '/' + key)[:-1] for key in keys}
    active = data['dma_is_active'] == 1
    read_busy |= active & (data['active_dir'] == 0)
    write_busy |= active & (data['active_dir'] == 1)
    full = data['slot_occupancy_r'] == args.depth
    source_enabled = ((data['rd_src_ptr_r'] < data['rd_src_end_r']) if naive
                      else (data['source_issue_enable'] == 1))
    demand = active & (data['rd_state'] == 1) & source_enabled
    if not naive:
        # A segment rollover can keep RD_RUN while its pointer is at end.
        # Count a capacity stall only if an actual source beat remains.
        for direction, bus in [(0, 'dcache'), (1, 'lmem')]:
            relevant = demand & full & (data['active_dir'] == direction)
            if np.any(relevant):
                ptr = sample(f'unit{i}_{bus}_rd_ptr', unit + '/' + bus + '_rd_ptr')[:-1]
                limit = sample(f'unit{i}_{bus}_rd_end', unit + '/' + bus + '_rd_end')[:-1]
                demand[relevant] &= ptr[relevant] < limit[relevant]
    dma_units.append(dict(index=i, max_occupancy=int(data['slot_occupancy_r'].max()),
                          full_active_cycles=int(np.sum(active & full)),
                          full_pending_read_cycles=int(np.sum(demand & full))))
assert np.array_equal(busy, read_busy | write_busy)
iv, ir = s['req_valid'][:-1] == 1, s['req_ready'][:-1] == 1
weight_wait = ((s['prealigner_out_valid'][:-1] == 1)
               & (s['pre_meta_valid_out'][:-1] == 1) & (s['weight_ready'][:-1] == 0))
psum_wait = ((s['post_txn_count'][:-1] > 0)
             & (s['post_head_psum_ready'][:-1] == 0))
psum_only = psum_wait & (s['post_head_scaled_ready'][:-1] == 1) & ((s['acc_result_credit'][:-1] > 0) | (s['acc_result_commit'][:-1] == 1))
node_stalls = {}
if naive:
    for key in ['psum_rd_order_block', 'psum_rd_pending_conflict', 'psum_rd_current_conflict']:
        node_stalls[key] = int(np.sum(sample(key, node + '/' + key)[:-1] == 1))
scheduler = {}
if naive and '-DGEMM_NAIVE_PSUM_READ_PRIORITY' in manifest['configs']:
    for key in ['psum_exact_raw_cycles', 'psum_waw_cycles', 'psum_war_cycles',
                'psum_write_full_cycles', 'psum_same_cycle_addr_cycles']:
        values = sample(key, node + '/' + key)
        scheduler[key] = int(values[-1] - values[0])
    wr_valid = sample('psum_wr_raw_valid', node + '/psum_wr_raw_bus_if/req_valid')[:-1] == 1
    wr_ready = sample('psum_wr_raw_ready', node + '/psum_wr_raw_bus_if/req_ready')[:-1] == 1
    credit_empty = s['acc_result_credit'][:-1] == 0
    scheduler['write_backpressure'] = int(np.sum(wr_valid & ~wr_ready))
    scheduler['result_credit_empty'] = int(np.sum(credit_empty))
    scheduler['write_backpressure_credit_empty'] = int(np.sum(wr_valid & ~wr_ready & credit_empty))
    credit_unavailable = credit_empty & (s['acc_result_commit'][:-1] == 0)
    scheduler['result_credit_unavailable'] = int(np.sum(credit_unavailable))
    scheduler['write_backpressure_no_result_credit'] = int(np.sum(wr_valid & ~wr_ready & credit_unavailable))
    pending_writes = sample('psum_write_valid', node + '/psum_write_valid')[:-1] != 0
    rd_valid = sample('psum_rd_wide_valid', node + '/psum_rd_wide_bus_if/req_valid')[:-1] == 1
    rd_ready = sample('psum_rd_wide_ready', node + '/psum_rd_wide_bus_if/req_ready')[:-1] == 1
    independent_reads = rd_valid & rd_ready & pending_writes
    scheduler['read_accept_with_pending_writes'] = int(independent_reads.sum())
    scheduler['read_accept_with_pending_writes_examples'] = (np.flatnonzero(independent_reads)[:8] + cfg).tolist()
breakdown = {}
for name, first, last in zip(phase_names, boundaries, boundaries[1:]):
    lo, hi = first-cfg, last-cfg
    breakdown[name] = dict(cycles=last-first,
        dma_read_busy=int(np.sum(read_busy[lo:hi])),
        dma_write_busy=int(np.sum(write_busy[lo:hi])),
        input_fire=int(np.sum((iv & ir)[lo:hi])),
        input_backpressure=int(np.sum((iv & ~ir)[lo:hi])),
        input_no_supply=int(np.sum((~iv)[lo:hi])),
        weight_wait=int(np.sum(weight_wait[lo:hi])),
        psum_wait=int(np.sum(psum_wait[lo:hi])))
result = dict(backend=manifest['backend'], m=manifest['m'], depth=args.depth,
              run=str(run.relative_to(ROOT)), gemm_cycles=end-cfg,
              boundaries=dict(zip(['cfg', 'first_input', 'last_input', 'last_acc_write', 'store', 'done'], boundaries)),
              phases=phases, scheduler=scheduler, phase_activity=breakdown, dma_units=dma_units, node_stalls=node_stalls,
              dma_counter_delta={key: int(v[-1]-v[0]) for key, v in counters.items()},
              dma_union_busy=int(np.sum(busy)), dma_read_union_busy=int(np.sum(read_busy)),
              dma_write_union_busy=int(np.sum(write_busy)), input_fires=len(input_edges),
              weight_wait=int(np.sum(weight_wait)), psum_wait=int(np.sum(psum_wait)),
              psum_only_wait=int(np.sum(psum_only)),
              input_backpressure=int(np.sum(iv & ~ir)),
              input_backpressure_dma_idle=int(np.sum(iv & ~ir & ~busy)),
              sampling='Strict preedge, period10ns, first risingedge5ns. Phase lengths are distances between handshake edges; activity counts use half-open phase windows and may overlap.')
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
