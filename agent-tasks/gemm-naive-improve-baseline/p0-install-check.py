#!/usr/bin/env python3
"""Check captured naive QCOL S/Z installs against immutable source tensors."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import fsdb_cli
NODE = '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node_naive'
HEADER = 'tests/regression/fpint_gemm_ffn_hw/test_vectors.h'


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def signal_paths():
    paths = {'clk': 'clk', 'reset': 'reset',
             'cfg': 'u_VX_gemm_ctrl_naive/cfg_start_fire',
             'entry': 'u_VX_gemm_ctrl_naive/cfg_reg_if/entry_id',
             'dma_start': 'gemm_dma_ctrl_if/start',
             'dma_idle': 'gemm_dma_ctrl_if/idle',
             'dma_done': 'gemm_dma_ctrl_if/done',
             'q_start': 'quant_param_dma_ctrl_if/start',
             'q_idle': 'quant_param_dma_ctrl_if/idle',
             'qdir': 'gemm_ctrl_if/qdir_tot', 'wtrans': 'gemm_ctrl_if/wtrans_tot',
             'owner_bank': 'qparam_install_bank_r', 'owner_seq': 'qparam_install_target_r',
             'owner_op': 'qparam_install_opcode_r'}
    for index in (7, 8, 9, 10, 29, 30, 31, 32):
        paths[f'cfg{index}'] = f'u_VX_gemm_ctrl_naive/cfg_reg_if/regs[{index}]'
    for name, prefix in [('dma', 'gemm_dma_ctrl_if/cmd'),
                         ('q', 'gemm_ctrl_if/quant_param_read_ctrl.cmd')]:
        for field in ('instr', 'rs1_data', 'rs2_data', 'rd', 'flags', 'work_seq', 'groups_eff'):
            paths[f'{name}_{field}'] = prefix + '.' + field
    for label, resource in [('s', 'scale'), ('z', 'zero')]:
        for field in ('req_valid', 'req_ready', 'req_data.data', 'req_data.byteen', 'req_data.addr'):
            paths[label + '_' + field.replace('.', '_')] = resource + '_gemm_bus_if/' + field
        paths[label + '_write'] = 'gemm_unit_v2_if/' + ('scale' if label == 's' else 'zero_point') + '_register_write'
        paths[label + '_bank'] = 'u_VX_gemm_compute_core/' + ('scale_reg_idx' if label == 's' else 'zp_reg_idx')
    for lane in range(4):
        for field in ('req_valid', 'req_ready', 'req_data.addr', 'req_data.tag.value',
                      'rsp_valid', 'rsp_ready', 'rsp_data.data', 'rsp_data.tag.value'):
            paths[f'lane{lane}_' + field.replace('.', '_')] = f'sz_lane_mem_if[{lane}]/' + field
    return {key: NODE + '/' + value for key, value in paths.items()}


def capture(wave, names=None):
    paths = {k: v for k, v in signal_paths().items() if names is None or k in names}
    def read(item):
        name, path = item
        r = fsdb_cli.report(str(wave), [path])
        if not r.data_rows:
            raise ValueError('Missing FSDB signal: ' + path)
        rows = [[int(t), int(v, 2) if re.fullmatch('[01]+', v) else None]
                for t, v in r.data_rows]
        return name, {'unit': r.time_unit, 'path': path, 'values': rows}
    with ThreadPoolExecutor(max_workers=4) as pool:
        return dict(pool.map(read, paths.items()))


def rising_samples(signals):
    positions = {key: 0 for key in signals if key != 'clk'}
    values = {key: None for key in positions}
    previous = None
    edge = -1
    for time, clock in signals['clk']['values']:
        rising = previous == 0 and clock == 1
        previous = clock
        if not rising:
            continue
        edge += 1
        for key in positions:
            rows = signals[key]['values']
            pos = positions[key]
            while pos < len(rows) and rows[pos][0] < time:
                values[key] = rows[pos][1]
                pos += 1
            positions[key] = pos
        yield edge, time, values


def expected_word(resource, row, col):
    # Generation-zero corrected tensor. No observed payload feeds this oracle.
    if resource == 's':
        return int.from_bytes(struct.pack('<e', 1 + (row % 17) / 16 + (col % 7) / 8), 'little')
    return ((3 * (row % 7) + col % 7) % 7 - 3) & 65535


def check(signals):
    records, loads, owners = [], {}, []
    active_dma = None
    lane_pending, lane_records = {}, []
    job = None
    for edge, time, v in rising_samples(signals):
        if v['reset'] is None or v['reset']:
            continue
        if v['cfg']:
            if job is not None or owners:
                raise ValueError('Only one nonempty invocation supported by this checker revision')
            job = {'entry_id': v['entry'], 'm': v['cfg29'], 'n': v['cfg30'],
                   'k': v['cfg31'], 'qblk': 1 << v['cfg32'],
                   's_base': v['cfg7'] + (v['cfg8'] << 32),
                   'z_base': v['cfg9'] + (v['cfg10'] << 32)}
            if [job[x] for x in ('m', 'n', 'k', 'qblk')] != [4, 512, 512, 32]:
                raise ValueError('Unsupported geometry: ' + str(job))
        if job is None:
            continue
        if v['dma_done'] and active_dma is not None:
            active_dma['complete_edge'] = edge
            loads[(active_dma['resource'], active_dma['lmem_base'])] = active_dma
            active_dma = None
        if v['dma_start'] and v['dma_idle']:
            if v['dma_instr'] & 255 == 0x10 and v['dma_rd'] in (2, 3):
                if active_dma is not None:
                    raise ValueError('Overlapping external quant loads')
                resource = 's' if v['dma_rd'] == 2 else 'z'
                active_dma = {'resource': resource, 'lmem_base': v['dma_rs1_data'],
                              'tensor_base': v['dma_rs2_data'], 'rows': v['dma_groups_eff'],
                              'start_edge': edge, 'bytes': v['dma_instr'] >> 8}
        if v['q_start'] and v['q_idle']:
            if v['qdir'] != 0 or v['wtrans'] != 0:
                raise ValueError('Only QCOL/WTRANS0 is currently supported')
            opcode = v['q_instr'] & 255
            if opcode not in (0x21, 0x24) or v['q_instr'] >> 8 != 32:
                raise ValueError('Unsupported quant descriptor')
            resource = 's' if opcode == 0x21 else 'z'
            source = v['q_rs2_data']
            candidates = [d for (r, base), d in loads.items()
                          if r == resource and base <= source and source + 32 <= base + d['rows'] * 128 * 2]
            if len(candidates) != 1:
                raise ValueError(f'Quant source lacks completed unique DMA owner: {source:x}, {candidates}')
            load = candidates[0]
            offset = source - load['lmem_base']
            local_row, local_byte = divmod(offset, 128 * 2)
            tensor_byte = load['tensor_base'] - job[resource + '_base'] + local_row * 512 * 2 + local_byte
            row, column_byte = divmod(tensor_byte, 512 * 2)
            col = column_byte // 2
            if tensor_byte % 2 or row >= 16 or col % 16 or col + 16 > 512:
                raise ValueError('Illegal quant source mapping')
            # Independent fixed N-fast work identity closes a potential blind
            # spot: a premature overwrite of the same LMEM buffer must not
            # redefine this command's expected generation to the newer load.
            sequence = v['q_work_seq'] - 1
            if not 0 <= sequence < 1024:
                raise ValueError('Quant generation outside expected invocation')
            n_tile, within_n_tile = divmod(sequence, 256)
            k_tile, within_dma_tile = divmod(within_n_tile, 64)
            micro_k, micro_n = divmod(within_dma_tile, 8)
            identity_row = (k_tile * 128 + micro_k * 16) // 32
            identity_col = n_tile * 128 + micro_n * 16
            if (row, col) != (identity_row, identity_col):
                raise ValueError('Source DMA mapping disagrees with fixed N-fast command identity')
            if owners:
                raise ValueError('Legacy combined quant owner overlap')
            owners.append({'resource': resource, 'opcode': opcode,
                           'bank': (v['q_flags'] >> 1) & 1, 'generation': v['q_work_seq'],
                           'source_lmem': source, 'source_tensor_byte': tensor_byte,
                           'source_load_start': load['start_edge'], 'source_load_complete': load['complete_edge'],
                           'q_accept_edge': edge, 'row': row, 'col': col,
                           'destination': v['q_rs1_data'], 'entry_id': job['entry_id']})
        for lane in range(4):
            prefix = f'lane{lane}_'
            if v[prefix + 'req_valid'] and v[prefix + 'req_ready']:
                if len(owners) != 1:
                    raise ValueError('Physical lane read lacks command owner')
                owner = owners[0]
                address = v[prefix + 'req_data_addr'] * 8
                tag = v[prefix + 'req_data_tag_value']
                key = lane, tag
                if key in lane_pending or address != owner['source_lmem'] + lane * 8:
                    raise ValueError('Physical lane source address/tag mapping mismatch')
                lane_pending[key] = dict(owner, lane=lane, request_edge=edge, tag=tag)
            if v[prefix + 'rsp_valid'] and v[prefix + 'rsp_ready']:
                key = lane, v[prefix + 'rsp_data_tag_value']
                if key not in lane_pending:
                    raise ValueError('Physical lane response has no reserved read')
                physical = lane_pending.pop(key)
                payload = v[prefix + 'rsp_data_data']
                if payload is None:
                    raise ValueError('Unknown physical lane response')
                physical['actual'] = [(payload >> (i * 16)) & 65535 for i in range(4)]
                physical['response_edge'] = edge
                physical['col'] += lane * 4
                lane_records.append(physical)
        for resource in ('s', 'z'):
            if not v[resource + '_write']:
                continue
            if not owners or owners[0]['resource'] != resource:
                raise ValueError('Register install without exact command owner')
            record = owners.pop(0)
            if (v['owner_bank'], v['owner_seq'], v['owner_op']) != (record['bank'], record['generation'], record['opcode']):
                raise ValueError('Node install ownership mismatch')
            if (v[resource + '_req_valid'], v[resource + '_req_ready'], v[resource + '_bank']) != (1, 1, record['bank']):
                raise ValueError('Actual register handshake or bank mismatch')
            if v[resource + '_req_data_byteen'] != 0xffffffff:
                raise ValueError('QCOL full beat has unexpected byte mask')
            payload = v[resource + '_req_data_data']
            if payload is None:
                raise ValueError('Unknown accepted payload')
            record.update(edge=edge, time=time, byteen=v[resource + '_req_data_byteen'],
                          bus_addr=v[resource + '_req_data_addr'],
                          actual=[(payload >> (16 * i)) & 65535 for i in range(16)])
            records.append(record)
    if owners or active_dma or lane_pending:
        raise ValueError('Incomplete waveform owners')
    for resource in ('s', 'z'):
        sequences = [r['generation'] for r in records if r['resource'] == resource]
        if sequences != list(range(1, 1025)):
            raise ValueError('Accepted quant command identities are not exactly the fixed N-fast sequence')
    if len(records) != 2048:
        raise ValueError('Expected 1024 scale plus 1024 zero installs: ' + str(len(records)))
    if len(lane_records) != len(records) * 4:
        raise ValueError("Incomplete physical lane coverage")
    return job, records, lane_records


def mismatches(records):
    errors = []
    for index, record in enumerate(records):
        for lane, actual in enumerate(record['actual']):
            expected = expected_word(record['resource'], record['row'], record['col'] + lane)
            if actual != expected:
                errors.append({'record': index, 'element': lane, 'actual': actual, 'expected': expected})
    return errors


def fault_controls(records):
    outcomes = []
    for resource in ('s', 'z'):
        target = next(i for i, r in enumerate(records) if r['resource'] == resource and r['row'] == 1)
        r = records[target]
        stale_record = next(x for x in records[:target] if x['resource'] == resource and x['row'] == r['row'] - 1 and x['col'] == r['col'])
        stale = list(stale_record['actual'])
        for name, start, length in [('element', 0, 1), ('physical_lane_8B', 4, 4), ('wide_beat_32B', 0, 16), ('stale_command', 0, 16)]:
            corrupted = [dict(rec, actual=list(rec['actual'])) for rec in records]
            corrupted[target]['actual'][start:start + length] = stale[start:start + length]
            errors = mismatches(corrupted)
            if not errors:
                raise AssertionError('Undetected captured-install fault: ' + resource + '/' + name)
            outcomes.append({'resource': resource, 'fault': name, 'record': target,
                             'changed_elements': length, 'detected_elements': len(errors),
                             'source': 'previous quant group, same logical columns',
                             'scope': 'captured accepted-install payload copy; no RTL fault injected'})
    return outcomes



def lane_fault_census(records):
    # Baseline whole-wave checking has already passed. Mutate only an observed
    # payload copy; checking that one record is sufficient because all others
    # remain byte-for-byte identical to the passing baseline.
    previous = {}
    attempted = detected = 0
    resources = {'s': 0, 'z': 0}
    for record in records:
        key = record['resource'], record['row'] - 1, record['col']
        if record['row'] and key in previous:
            stale = previous[key]['actual']
            for physical_lane in range(4):
                changed = dict(record, actual=list(record['actual']))
                start = physical_lane * 4
                changed['actual'][start:start + 4] = stale[start:start + 4]
                attempted += 1
                resources[record['resource']] += 1
                errors = mismatches([changed])
                if len(errors) != 4:
                    raise AssertionError('Incomplete previous-group physical-lane fault detection')
                detected += 1
        previous.setdefault((record['resource'], record['row'], record['col']), record)
    if attempted != 7680 or attempted != detected:
        raise AssertionError('Unexpected physical lane fault census size')
    return {'attempted': attempted, 'detected': detected, 'missed': attempted - detected,
            'per_resource': resources, 'physical_lanes': [0, 1, 2, 3],
            'replacement': 'previous accepted group, same columns, captured 8-byte lane payload',
            'scope': 'post-capture accepted-install payload substitution; no live RTL injection'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, default=ROOT / 'agent-tasks/gemm-naive-improve-baseline/p0-baseline/naive-m4-retry1')
    parser.add_argument('--prefix', type=Path, default=ROOT / 'agent-tasks/gemm-naive-improve-baseline/p0-install-naive-m4')
    args = parser.parse_args()
    wave = args.run / 'wave.fsdb'
    manifest = json.loads((args.run / 'manifest.json').read_text())
    assert manifest['source_hashes'][HEADER] == sha(ROOT / HEADER)
    snapshot = args.prefix.with_name(args.prefix.name + '-snapshot.json')
    wave_sha = sha(wave)
    if snapshot.exists():
        captured = json.loads(snapshot.read_text())
        assert captured['wave_sha256'] == wave_sha
        signals = captured['signals']
        missing = set(signal_paths()) - set(signals)
        if missing:
            signals.update(capture(wave, missing))
            captured['signals'] = signals
            snapshot.write_text(json.dumps(captured) + '\n')
    else:
        signals = capture(wave)
        snapshot.write_text(json.dumps({'wave': str(wave.resolve()), 'wave_sha256': wave_sha, 'signals': signals}) + '\n')
    job, records, lane_records = check(signals)
    errors = mismatches(records)
    lane_errors = mismatches(lane_records)
    if lane_errors:
        raise AssertionError(f"Physical lane payload mismatch: {lane_errors[:8]}")
    if errors:
        raise AssertionError(f'Accepted payload mismatch: {errors[:8]} ({len(errors)} total)')
    coverage = {r: {'installs': sum(x['resource'] == r for x in records),
                    'elements': 16 * sum(x['resource'] == r for x in records),
                    'unique_tensor_elements': len({(x['row'], x['col'] + i) for x in records if x['resource'] == r for i in range(16)}),
                    'banks': sorted({x['bank'] for x in records if x['resource'] == r}),
                    'generations': len({x['generation'] for x in records if x['resource'] == r})}
                for r in ('s', 'z')}
    faults = fault_controls(records)
    result = {'status': 'pass', 'job': job, 'coverage': coverage, 'payload_mismatches': 0, 'physical_lane_responses': len(lane_records), 'physical_lane_mismatches': 0,
              'wave_sha256': wave_sha, 'vector_source_sha256': sha(ROOT / HEADER),
              'sampling': 'strictly before rising clock edge; pre-NBA accepted register installs',
              'fault_controls': faults, 'physical_lane_fault_census': lane_fault_census(records),
              'limitations': ['QCOL/WTRANS0 M4 K512 N512 only', 'one job generation0',
                              'faults modify captured interface snapshots, not live RTL',
                              'QROW/layout/tails/poisoned repeat jobs remain pending'],
              'records': records, 'physical_lane_records': lane_records}
    output = args.prefix.with_name(args.prefix.name + '-results.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('status', 'coverage', 'payload_mismatches', 'physical_lane_responses', 'physical_lane_mismatches', 'fault_controls')}, indent=2))

if __name__ == '__main__':
    main()
