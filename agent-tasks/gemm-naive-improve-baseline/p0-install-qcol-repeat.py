#!/usr/bin/env python3
"""Read-only QCOL/WTRANS1 two-job physical response and accepted-install oracle."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
SPEC = importlib.util.spec_from_file_location('qrow_helpers', Path(__file__).with_name('p0-install-qrow.py'))
helpers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helpers)
base = helpers.base
rising_samples = base.rising_samples

def check(signals):
    records, loads, owners = [], {}, []
    active_dma = None
    lane_pending, lane_records = {}, []
    job = None
    jobs, resetting, epoch = [], False, 0
    for edge, time, v in rising_samples(signals):
        if v['reset'] not in (0, 1):
            continue
        if v['reset']:
            if not resetting:
                if owners or active_dma or lane_pending:
                    raise ValueError('Reset discarded unfinished transport')
                epoch += 1
                job, loads = None, {}
            resetting = True
            continue
        resetting = False
        if v['cfg']:
            if job is not None or owners:
                raise ValueError('Only one nonempty invocation supported by this checker revision')
            job = {'entry_id': v['entry'], 'm': v['cfg29'], 'n': v['cfg30'],
                   'k': v['cfg31'], 'qblk': 1 << v['cfg32'],
                   's_base': v['cfg7'] + (v['cfg8'] << 32),
                   'z_base': v['cfg9'] + (v['cfg10'] << 32)}
            job.update(host_generation=len(jobs), epoch=epoch)
            jobs.append(job)
            if epoch != len(jobs) or job['entry_id'] != 0:
                raise ValueError('Unexpected reset/job epoch schedule')
            if [job[x] for x in ('m', 'n', 'k', 'qblk')] != [16, 64, 64, 32]:
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
            if v['qdir'] != 0 or v['wtrans'] != 1:
                raise ValueError('Only QCOL/WTRANS1 is currently supported')
            opcode = v['q_instr'] & 255
            if opcode not in (0x21, 0x24) or v['q_instr'] >> 8 != 32:
                raise ValueError('Unsupported quant descriptor')
            resource = 's' if opcode == 0x21 else 'z'
            if (v['q_bounds'], v['q_seg'], v['q_source_stride'], v['q_dest_stride']) != (1, 32, 256, 0):
                raise ValueError('Unexpected physical QCOL descriptor shape')
            source = v['q_rs2_data']
            candidates = [d for (r, base), d in loads.items()
                          if r == resource and base <= source and source + 32 <= base + d['rows'] * 128 * 2]
            if len(candidates) != 1:
                raise ValueError(f'Quant source lacks completed unique DMA owner: {source:x}, {candidates}')
            load = candidates[0]
            offset = source - load['lmem_base']
            local_row, local_byte = divmod(offset, 128 * 2)
            tensor_byte = load['tensor_base'] - job[resource + '_base'] + local_row * 64 * 2 + local_byte
            row, column_byte = divmod(tensor_byte, 64 * 2)
            col = column_byte // 2
            if tensor_byte % 2 or row >= 2 or col % 16 or col + 16 > 64:
                raise ValueError('Illegal quant source mapping')
            # Independent fixed N-fast work identity closes a potential blind
            # spot: a premature overwrite of the same LMEM buffer must not
            # redefine this command's expected generation to the newer load.
            sequence = v['q_work_seq'] - 1
            if not 0 <= sequence < 16:
                raise ValueError('Quant sequence outside captured geometry')
            micro_k, micro_n = divmod(sequence, 4)
            identity_row = micro_k * 16 // 32
            identity_col = micro_n * 16
            if (row, col) != (identity_row, identity_col):
                raise ValueError('Source DMA mapping disagrees with fixed N-fast command identity')
            if owners:
                raise ValueError('Legacy combined quant owner overlap')
            owners.append({'resource': resource, 'opcode': opcode,
                           'bank': (v['q_flags'] >> 1) & 1, 'generation': v['q_work_seq'],
                           'source_lmem': source, 'source_tensor_byte': tensor_byte,
                           'source_load_start': load['start_edge'], 'external_load': dict(load),
                           'descriptor_bounds': v['q_bounds'], 'descriptor_seg': v['q_seg'],
                           'descriptor_source_stride': v['q_source_stride'], 'source_load_complete': load['complete_edge'],
                           'q_accept_edge': edge, 'row': row, 'col': col,
                           'destination': v['q_rs1_data'], 'entry_id': job['entry_id'],
                           'host_generation': job['host_generation'], 'epoch': epoch})
        for lane in range(4):
            prefix = f'lane{lane}_'
            if v[prefix + 'req_valid'] and v[prefix + 'req_ready']:
                if len(owners) != 1:
                    raise ValueError('Physical lane read lacks command owner')
                owner = owners[0]
                address = v[prefix + 'req_data_addr'] * 8
                tag = v[prefix + 'req_data_tag_value']
                key = lane, tag
                if v[prefix + 'req_data_byteen'] != 255:
                    raise ValueError('Unexpected lane byte mask')
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
            responses = [r for r in lane_records if (r['host_generation'], r['resource'], r['generation']) == (record['host_generation'], resource, record['generation'])]
            if sorted(r['lane'] for r in responses) != [0, 1, 2, 3] or lane_pending:
                raise ValueError('Install precedes complete unique physical lane return')
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
    if len(jobs) != 2:
        raise ValueError('Expected exactly two reset-separated jobs')
    for generation in range(2):
        for resource in ('s', 'z'):
            sequences = [r['generation'] for r in records if r['resource'] == resource and r['host_generation'] == generation]
            if sequences != list(range(1, 17)):
                raise ValueError('Per-job quant sequence differs from fixed N-fast stream')
    if len(records) != 64 or len(lane_records) != 256:
        raise ValueError('Incomplete command/lane coverage')
    return jobs, records, lane_records

def errors(records):
    return [{'record': index, 'element': i, 'actual': value,
             'expected': helpers.expected(r['resource'], r['row'], r['col'] + i, r['host_generation'])}
            for index, r in enumerate(records) for i, value in enumerate(r['actual'])
            if value != helpers.expected(r['resource'], r['row'], r['col'] + i, r['host_generation'])]


def controls(records, physical):
    outcomes = []
    for resource in ('s', 'z'):
        target = next(r for r in records if r['resource'] == resource and r['row'] == 1 and r['host_generation'] == 0)
        stale = next(r for r in records if r['resource'] == resource and r['row'] == 0 and r['col'] == target['col'] and r['host_generation'] == 0)
        for fault, start, length in [('element', 0, 1), ('physical_lane_8B', 4, 4), ('wide_beat_32B', 0, 16), ('stale_whole_command', 0, 16)]:
            changed = dict(target, actual=list(target['actual']))
            changed['actual'][start:start+length] = stale['actual'][start:start+length]
            detected = len(errors([changed]))
            assert detected == length
            outcomes.append(dict(resource=resource, fault=fault, changed=length, detected=detected))
    lookup = {(r['host_generation'], r['resource'], r['generation']): r for r in records}
    previous_job = 0
    for r in records:
        if r['host_generation'] == 1:
            stale = lookup[(0, r['resource'], r['generation'])]
            assert len(errors([dict(r, actual=stale['actual'])])) == 16
            previous_job += 1
    previous_physical = {(r['host_generation'], r['resource'], r['generation'], r['lane']): r for r in physical}
    previous_job_lanes = 0
    for r in physical:
        if r['host_generation'] == 1:
            stale = previous_physical[(0, r['resource'], r['generation'], r['lane'])]
            assert len(errors([dict(r, actual=stale['actual'])])) == 4
            previous_job_lanes += 1
    detected = equivalent = 0
    for r in records:
        if r['generation'] == 1:
            continue
        stale = lookup[(r['host_generation'], r['resource'], r['generation'] - 1)]
        if errors([dict(r, actual=stale['actual'])]):
            detected += 1
        else:
            assert r['actual'] == stale['actual']
            equivalent += 1
    assert previous_job == 32 and previous_job_lanes == 128
    return dict(representative=outcomes, previous_job_commands_detected=previous_job,
                previous_job_physical_lanes_detected=previous_job_lanes,
                previous_adjacent_same_job_commands=dict(detected=detected, payload_equivalent=equivalent),
                scope='copied captured payload substitution; no live RTL injection')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, default=Path(__file__).parent / 'p0-baseline/naive-qcol-wt1-repeat2')
    args = parser.parse_args()
    manifest_path = args.run / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    assert manifest['returncode'] == 0 and re.search(r'^PASSED$', (args.run / 'wrapper.log').read_text(), re.M)
    assert tuple(manifest[k] for k in ('backend','m','k','n','qdir','wtrans','repeat','tagged')) == ('naive',16,64,64,0,1,2,False)
    checked_sources = {}
    for name, digest in manifest['source_hashes'].items():
        if name.startswith('hw/rtl/') or name in (base.HEADER, 'tests/regression/fpint_gemm_ffn_hw_naive/main.cpp'):
            assert base.sha(base.ROOT / name) == digest, name
            checked_sources[name] = digest
    wave = args.run / 'wave.fsdb'
    wave_hash = base.sha(wave)
    prefix = Path(__file__).with_suffix('')
    snapshot = prefix.with_name(prefix.name + '-snapshot.json')
    paths = helpers.paths_for(32)
    if snapshot.exists():
        captured = json.loads(snapshot.read_text())
        assert captured['wave_sha256'] == wave_hash
        signals = captured['signals']
        assert all(signals[k]['path'] == path for k, path in paths.items())
    else:
        signals = helpers.capture(wave, paths)
        snapshot.write_text(json.dumps(dict(wave=str(wave.resolve()), wave_sha256=wave_hash, signals=signals)) + '\n')
    jobs, installs, physical = check(signals)
    assert not errors(installs), errors(installs)[:8]
    assert not errors(physical), errors(physical)[:8]
    result = dict(status='pass', geometry={k:manifest[k] for k in ('m','k','n','qdir','wtrans','repeat','tagged')},
                  jobs=jobs, installs=len(installs), installed_elements=sum(len(r['actual']) for r in installs),
                  physical_responses=len(physical), physical_elements=sum(len(r['actual']) for r in physical),
                  payload_mismatches=0, physical_mismatches=0,
                  reset_between_jobs=True, no_reset_lifecycle_proven=False,
                  actual_install_byteen=sorted({r['byteen'] for r in installs}),
                  banks=sorted({r['bank'] for r in installs}),
                  unique_elements_per_job_resource={str(g):{s:len({(r['row'],r['col']+i) for r in installs if r['host_generation']==g and r['resource']==s for i in range(16)}) for s in ('s','z')} for g in range(2)},
                  sampling='strictly before rising edge, pre-NBA accepted handshakes',
                  wave_sha256=wave_hash, manifest_sha256=base.sha(manifest_path), checked_sources=checked_sources,
                  checker_sha256=base.sha(Path(__file__)), helper_sha256=base.sha(Path(helpers.__file__)), base_helper_sha256=base.sha(Path(base.__file__)),
                  controls=controls(installs,physical),
                  limitations=['legacy command metadata is checked only where physically present',
                               'no post-edge register-array readback or improve payload proof',
                               'reset-separated repeated jobs do not prove no-reset lifecycle',
                               'fixed full-width QCOL descriptors; arbitrary N/K tails not covered'],
                  installed_records=installs, physical_records=physical)
    prefix.with_name(prefix.name+'-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('installed_records','physical_records','checked_sources')},indent=2))

if __name__ == '__main__':
    main()
