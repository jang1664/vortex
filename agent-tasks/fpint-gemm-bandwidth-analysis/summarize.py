"""Validate and summarize the per-cycle arrays exported with fsdb_cli."""
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/hw_analysis/improve_vs_naive/fsdb_m4'
result = {}
for name in ('naive', 'improve'):
    folder = OUT / name
    a = np.load(folder / 'timeline.npz')
    counters = json.loads((folder / 'counters.json').read_text())
    manifest = json.loads((folder / 'manifest.json').read_text())
    assert manifest['returncode'] == 0 and manifest['passed']
    cycles = len(a['input_fire'])
    assert cycles == counters['gemm_node.total_cycles']
    for signal in ('input_fire', 'input_valid', 'input_ready',
                   'input_dma_start', 'external_dma_busy'):
        assert np.isin(a[signal], [0, 1]).all(), signal
    assert np.array_equal(a['input_fire'], a['input_valid'] & a['input_ready'])
    starts = np.flatnonzero(a['input_dma_start'])
    inputs = np.flatnonzero(a['input_fire'])
    assert len(starts) == 1024 and len(inputs) == 4096
    rows = inputs.reshape(-1, 4)
    assert (rows[:, 0] >= starts).all()
    dma = 'cpu_dma' if name == 'naive' else 'hbm_dma.aggregate'
    read_bytes = counters[dma + '.rd_bytes']
    write_bytes = counters[dma + '.wr_bytes']
    assert (read_bytes, write_bytes) == (180224, 4096)
    busy = int(a['external_dma_busy'].sum())

    def distribution(values):
        return dict(zip(('min', 'median', 'max'),
                        map(float, np.percentile(values, [0, 50, 100]))))

    result[name] = {
        'cycles': cycles,
        'external_read_bytes': read_bytes,
        'external_write_bytes': write_bytes,
        'external_dma_busy_cycles': busy,
        'external_dma_idle_cycles': cycles - busy,
        'useful_bytes_per_external_dma_busy_cycle': (read_bytes + write_bytes) / busy,
        'input_fire_cycles': len(inputs),
        'input_fire_percent': 100 * len(inputs) / cycles,
        'input_start_interval': distribution(np.diff(starts)),
        'start_to_first_input': distribution(rows[:, 0] - starts),
        'first_to_last_input': distribution(rows[:, -1] - rows[:, 0]),
    }
    if name == 'naive':
        assert (rows[:-1, -1] < starts[1:]).all()
        result[name]['parent_full_external_dma_idle_cycles'] = int(np.count_nonzero(
            (a['parent_full'] == 1) & (a['external_dma_busy'] == 0)))
        wb = np.flatnonzero(a['tagged_writeback'])
        done = np.flatnonzero(a['packetizer_command_done'])
        assert len(wb) == len(done) == len(starts)
        assert (wb >= rows[:, -1]).all() and (done >= wb).all()
        assert (starts[1:] > done[:-1]).all()
        result[name].update(
            last_input_to_writeback=distribution(wb - rows[:, -1]),
            writeback_to_done=distribution(done - wb),
            done_to_next_start=distribution(starts[1:] - done[:-1]),
        )
        phases = [dict(start=int(s), first_input=int(rows[i, 0]),
                       last_input=int(rows[i, -1]), writeback=int(wb[i]),
                       done=int(done[i]),
                       next_start=int(starts[i + 1]) if i + 1 < len(starts) else None)
                  for i, s in enumerate(starts)]
        (folder / 'command_phases.json').write_text(json.dumps(phases, indent=2) + '\n')
        assert not a['external_dma_busy'][1501:1675].any()
    else:
        result[name]['max_input_context_count'] = int(a['input_context_count'].max())

n, i = result['naive'], result['improve']
gap = n['cycles'] - i['cycles']
busy_gap = n['external_dma_busy_cycles'] - i['external_dma_busy_cycles']
result['comparison'] = {
    'gemm_speedup': n['cycles'] / i['cycles'],
    'total_cycle_difference': gap,
    'external_dma_busy_difference': busy_gap,
    'external_dma_idle_difference': gap - busy_gap,
    'external_dma_busy_difference_percent_of_total_difference': 100 * busy_gap / gap,
    'external_dma_idle_difference_percent_of_total_difference': 100 * (gap - busy_gap) / gap,
    'useful_transfer_rate_ratio': n['external_dma_busy_cycles'] / i['external_dma_busy_cycles'],
}
(OUT / 'analysis_summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
