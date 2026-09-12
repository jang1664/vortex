"""Check accepted microtile traversal and input gaps in a completed FSDB."""
import argparse
import json
from pathlib import Path
import re
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('run', type=Path)
parser.add_argument('order', choices=['kfast', 'nfast'])
parser.add_argument('output', type=Path)
args = parser.parse_args()
run = args.run.resolve()
manifest = json.loads((run / 'manifest.json').read_text())
assert manifest['passed'] and not manifest['source_changes_during_run']
done = [line for line in (run / 'simv.log').read_text().splitlines()
        if line.startswith('GEMM_LATENCY_DONE ')]
assert len(done) == 1
meta = dict(re.findall(r'(\w+)=([^\s]+)', done[0]))
start, end = int(meta['e_cfg']), int(meta['e_valid'])
times = np.arange(start, end, dtype=np.int64) * 10000 + 5000
node = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node'
fsm = node + '/u_VX_gemm_ctrl/u_VX_gemm_fsm'
compute = node + '/u_VX_gemm_unit_v2/u_compute_core'
paths = {name: fsm + '/' + name for name in
         ['gemm_arm_parent_accept', 'nt_mxu_q', 'kt_mxu_q', 'tile_cur_q',
          'pending_work_seq_o']}
paths.update(input_valid=compute + '/input_bus_if/req_valid',
             input_ready=compute + '/input_bus_if/req_ready',
             compute_valid=compute + '/prealigner_out_valid',
             meta_valid=compute + '/pre_meta_valid_out',
             weight_ready=compute + '/weight_ready')
samples = {}
for name, path in paths.items():
    result = fsdb_cli.report(str(run / 'wave.fsdb'), [path])
    assert result.data_rows and result.time_unit == '1ps', path
    t = np.array([int(row[0]) for row in result.data_rows], dtype=np.int64)
    v = np.array([int(row[1], 2) if re.fullmatch('[01]+', row[1]) else -1
                  for row in result.data_rows], dtype=np.int64)
    idx = np.searchsorted(t, times, side='left') - 1
    samples[name] = v[np.maximum(idx, 0)]
    samples[name][idx < 0] = -1
s = samples
accepted = np.flatnonzero(s['gemm_arm_parent_accept'] == 1)
assert len(accepted) == (1024 if manifest['m'] == 4 else 2048)
coords = np.stack([s['tile_cur_q'][accepted], s['nt_mxu_q'][accepted],
                   s['kt_mxu_q'][accepted]], axis=1)
assert np.all(coords >= 0)
# This comparison uses 128x128 macro N/K tiles and 16x16 microtiles.
for tile in np.unique(coords[:, 0]):
    actual = coords[coords[:, 0] == tile, 1:].tolist()
    expected = ([(n, k) for n in range(8) for k in range(8)]
                if args.order == 'kfast' else
                [(n, k) for k in range(8) for n in range(8)])
    assert actual == [list(pair) for pair in expected], (tile, actual[:10])
    seq = s['pending_work_seq_o'][accepted][coords[:, 0] == tile]
    assert np.all(np.diff(seq) == 1), (tile, seq.tolist())
valid, ready = s['input_valid'] == 1, s['input_ready'] == 1
fires = np.flatnonzero(valid & ready)
assert len(fires) == manifest['m'] * 1024
gap, count = np.unique(np.diff(fires), return_counts=True)
result = dict(run=str(run.relative_to(ROOT)), order=args.order,
              gemm_cycles=end-start, accepted_commands=len(accepted),
              first_coordinates=coords[:10].tolist(), traversal_checked=True,
              input_fires=len(fires), input_backpressure=int(np.sum(valid & ~ready)),
              input_empty_ready=int(np.sum(~valid & ready)),
              compute_weight_wait=int(np.sum((s['compute_valid'] == 1)
                  & (s['meta_valid'] == 1) & (s['weight_ready'] == 0))),
              input_gap_hist=dict(zip(map(str, gap.tolist()), count.tolist())),
              sampling='Strictly before rising edges, period10ns, first edge5ns.')
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
