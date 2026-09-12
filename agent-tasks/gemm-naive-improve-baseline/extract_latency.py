#!/usr/bin/env python3
"""Independently sample controller ports immediately before FSDB clock edges."""
import argparse
import csv
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli

CORE = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core'
FIELDS = ['e_cfg', 'e_store', 'e_valid', 'e_hs', 'L_gemm', 'L_store',
          'L_finalize', 'L_delivery', 'L_to_handshake', 'entry_id', 'stores']


def read_signal(wave, signal, cache):
    # Output directories are unique per run; saved CSVs are reviewable evidence.
    report = fsdb_cli.report(str(wave), [signal])
    if not report.data_rows:
        raise ValueError(f'No samples for {signal}')
    with cache.open('w') as output:
        writer = csv.writer(output)
        writer.writerow([f'Time({report.time_unit})', signal])
        writer.writerows(report.data_rows)
    values = []
    for row in report.data_rows:
        raw = row[1].strip()
        value = int(raw, 2) if re.fullmatch('[01]+', raw) else None
        values.append((int(row[0]), value))
    return report.time_unit, values


def sample_jobs(signals):
    """Strict-before-edge values exclude synchronous NBA updates at that edge."""
    clock = signals['clk']
    previous = None
    edges = []
    for time, value in clock:
        if value == 1 and previous == 0:
            edges.append(time)
        previous = value
    positions = {name: 0 for name in signals if name != 'clk'}
    current = {name: None for name in positions}
    pending, complete = [], []
    active = None
    sequence, epoch = 0, 0
    resetting = False
    for edge, time in enumerate(edges):
        for name in positions:
            values = signals[name]
            position = positions[name]
            while position < len(values) and values[position][0] < time:
                current[name] = values[position][1]
                position += 1
            positions[name] = position
        if current['reset'] is None:
            continue
        if current['reset']:
            if not resetting:
                epoch += 1
            resetting = True
            pending, active, sequence = [], None, 0
            continue
        resetting = False
        # Unknown handshake controls invalidate evidence instead of becoming zero.
        for name in ['cfg', 'store', 'valid', 'ready']:
            if current[name] is None:
                raise ValueError(f'Unknown {name} at edge {edge}, time {time}')
        if current['cfg'] and current['cfg_control'] is None:
            raise ValueError('Unknown control on accepted configuration')
        if current['cfg'] and (current['cfg_control'] & 1):
            if (active is not None and 'e_valid' not in active
                    and not (current['valid'] and current['done_id'] == active['entry_id'])):
                raise ValueError('Overlapping compute invocation')
            active = dict(epoch=epoch, job=sequence, entry_id=current['cfg_id'],
                          e_cfg=edge, stores=0)
            pending.append(active)
            sequence += 1
        if current['store']:
            if active is None or 'e_valid' in active:
                raise ValueError('Unowned store completion')
            active['e_store'] = edge
            active['stores'] += 1
        if current['valid']:
            matches = [j for j in pending if j['entry_id'] == current['done_id']]
            if not matches:
                raise ValueError('Unowned done notification')
            job = matches[0]
            if 'e_store' not in job:
                raise ValueError('Done before any store completion')
            job.setdefault('e_valid', edge)
            if current['ready']:
                job['e_hs'] = edge
                job.update(L_gemm=job['e_valid'] - job['e_cfg'],
                           L_store=job['e_store'] - job['e_cfg'],
                           L_finalize=job['e_valid'] - job['e_store'],
                           L_delivery=edge - job['e_valid'],
                           L_to_handshake=edge - job['e_cfg'])
                assert job['e_cfg'] <= job['e_store'] <= job['e_valid'] <= edge
                complete.append(job)
                pending.remove(job)
                if active is job:
                    active = None
    if pending:
        raise ValueError('Waveform ends with incomplete invocation observations')
    if not complete:
        raise ValueError('No completed invocations in waveform')
    return complete


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backend', choices=['naive', 'improve'])
    parser.add_argument('wave', type=Path)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--controller', help='Override controller hierarchy for unit tests')
    parser.add_argument('--metadata-node', action='store_true',
                        help='Sample the integrated naive metadata node endpoints')
    args = parser.parse_args()
    if args.metadata_node and args.backend != 'naive':
        parser.error('--metadata-node applies only to naive')
    args.output.mkdir(parents=True, exist_ok=False)
    suffix = '_naive' if args.backend == 'naive' else ''
    ctrl = args.controller or CORE + f'/gemm_node{suffix}/u_VX_gemm_ctrl{suffix}'
    # These are DUT signals, never the observation layer's timestamp registers.
    paths = dict(clk='clk', reset='reset',
                 cfg='cfg_start_fire' if suffix else 'cfg_fire',
                 store='output_store_done_i', valid='done_if/valid',
                 ready='done_if/ready', cfg_id='cfg_reg_if/entry_id',
                 cfg_control='cfg_reg_if/regs[0]',
                 done_id='done_if/entry_id')
    if args.metadata_node:
        ctrl = args.controller or CORE + '/gemm_node_naive'
        paths.update(store='output_store_done', cfg_id='issue_if/entry_id',
                     cfg_control='issue_if/regs[0]')
    signals, units = {}, set()
    for name, leaf in paths.items():
        unit, signals[name] = read_signal(args.wave, ctrl + '/' + leaf,
                                          args.output / f'{name}.csv')
        units.add(unit)
    if len(units) != 1:
        raise ValueError(f'Inconsistent FSDB time units: {units}')
    jobs = sample_jobs(signals)
    result = dict(backend=args.backend, wave=str(args.wave.resolve()),
                  controller=ctrl, time_unit=units.pop(), jobs=jobs,
                  sampling='strictly before rising edge; first rising edge index 0',
                  store_endpoint=paths['store'],
                  visibility='controller_retirement_only', log_match=None)
    if args.log:
        logged = []
        for line in args.log.read_text(errors='replace').splitlines():
            if line.startswith('GEMM_LATENCY_DONE '):
                row = dict(re.findall(r'(\w+)=([^\s]+)', line))
                if row.get('backend') == args.backend:
                    logged.append(row)
        if len(logged) != len(jobs):
            raise ValueError(f'Job count differs: FSDB {len(jobs)}, log {len(logged)}')
        differences = []
        for i, (wave_job, log_job) in enumerate(zip(jobs, logged)):
            for field in FIELDS + ['epoch', 'job']:
                if wave_job[field] != int(log_job[field]):
                    differences.append((i, field, wave_job[field], log_job[field]))
        result['log_match'] = not differences
        result['differences'] = differences
    (args.output / 'latency.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if result['log_match'] is False:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
