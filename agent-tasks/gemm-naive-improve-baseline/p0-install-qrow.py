#!/usr/bin/env python3
"""Captured naive QROW quant source/install checks, including reset-separated jobs."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location('install_base', Path(__file__).with_name('p0-install-check.py'))
base = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(base)


def paths_for(width):
    paths = base.signal_paths()
    for lane in range(width // 8):
        for field in ('req_valid', 'req_ready', 'req_data.addr', 'req_data.byteen', 'req_data.tag.value',
                      'rsp_valid', 'rsp_ready', 'rsp_data.data', 'rsp_data.tag.value'):
            paths[f'lane{lane}_' + field.replace('.', '_')] = base.NODE + f'/sz_lane_mem_if[{lane}]/' + field
    for key, leaf in [('q_bounds', 'bounds[0]'), ('q_seg', 'seg_size'),
                      ('q_source_stride', 'src_strides[0]'), ('q_dest_stride', 'dst_strides[0]')]:
        paths[key] = base.NODE + '/quant_param_dma_ctrl_if/' + leaf
    return paths


def capture(wave, paths):
    def read(item):
        name, path = item
        report = base.fsdb_cli.report(str(wave), [path])
        if not report.data_rows:
            raise ValueError('Missing signal: ' + path)
        # Keep mixed unknown vectors: inactive bytes may be unknown while the
        # one byte-enabled FP16 element is fully known and checkable.
        return name, {'unit': report.time_unit, 'path': path,
                      'values': [[int(t), int(v, 2) if re.fullmatch('[01]+', v) else v]
                                 for t, v in report.data_rows]}
    with ThreadPoolExecutor(max_workers=4) as pool:
        return dict(pool.map(read, paths.items()))


def words(payload, count):
    if isinstance(payload, int):
        return [(payload >> (16 * i)) & 65535 for i in range(count)]
    if not isinstance(payload, str):
        return [None] * count
    payload = payload.rjust(count * 16, 'x')
    return [int(payload[-16 * (i + 1):len(payload) - 16 * i], 2)
            if re.fullmatch('[01]{16}', payload[-16 * (i + 1):len(payload) - 16 * i]) else None
            for i in range(count)]


def expected(resource, row, col, generation):
    if resource == 's':
        import struct
        value = 1 + ((row % 17 + generation % 17) % 17) / 16 + (col % 7) / 8
        return int.from_bytes(struct.pack('<e', value), 'little')
    return ((3 * (row % 7) + col % 7 + generation % 7) % 7 - 3) & 65535


def errors(records):
    result = []
    for number, record in enumerate(records):
        for element, actual in enumerate(record['actual']):
            if (record['byteen'] >> (element * 2)) & 3:
                value = expected(record['resource'], record['row'], record['col'], record['host_generation'])
                if actual != value:
                    result.append({'record': number, 'element': element, 'actual': actual, 'expected': value})
    return result


def check(signals, manifest, width):
    mxu = width // 2
    lane_count = width // 8
    jobs, installs, physical = [], [], []
    accepted_commands = set()
    resetting, epoch = False, 0
    job, owner, external = None, None, None
    loads, pending = {}, {}
    n, k = manifest['n'], manifest['k']
    m, repetitions, wtrans = manifest['m'], manifest['repeat'], manifest['wtrans']
    if (n, k, manifest['qdir']) != (64, 64, 1) or not 1 <= m <= mxu or wtrans not in (0, 1) or repetitions < 2 or not manifest['tagged']:
        raise ValueError('Requires one M microtile, K64 N64 QROW, tagged and at least two reset-separated jobs')
    for edge, time, v in base.rising_samples(signals):
        if v['reset'] not in (0, 1):
            continue
        if v['reset'] == 1:
            if not resetting:
                if owner is not None or external is not None or pending:
                    raise ValueError('Reset discarded incomplete owned transport')
                epoch += 1
                job, owner, external = None, None, None
                loads, pending = {}, {}
            resetting = True
            continue
        resetting = False
        if v['cfg'] == 1:
            if job is not None:
                raise ValueError('Unexpected non-reset repeated invocation in this capture contract')
            generation = len(jobs)
            job = {'epoch': epoch, 'host_generation': generation, 'entry_id': v['entry'],
                   'm': v['cfg29'], 'n': v['cfg30'], 'k': v['cfg31'],
                   'qblk': 1 << v['cfg32'], 'e_cfg': edge,
                   's_base': v['cfg7'] + (v['cfg8'] << 32),
                   'z_base': v['cfg9'] + (v['cfg10'] << 32)}
            if (job['m'], job['n'], job['k'], job['qblk'], job['entry_id'], epoch) != (m, n, k, 32, 0, generation + 1):
                raise ValueError('Accepted job does not match immutable host-generation schedule')
            jobs.append(job)
        if job is None:
            continue
        if v['dma_done'] == 1 and external is not None:
            external['complete_edge'] = edge
            loads[(external['resource'], external['lmem_base'])] = external
            external = None
        if v['dma_start'] == 1 and v['dma_idle'] == 1:
            if v['dma_instr'] & 255 == 0x10 and v['dma_rd'] in (2, 3):
                if external is not None:
                    raise ValueError('Overlapping external loads')
                resource = 's' if v['dma_rd'] == 2 else 'z'
                external = dict(resource=resource, lmem_base=v['dma_rs1_data'],
                                tensor_base=v['dma_rs2_data'], rows=v['dma_groups_eff'], start_edge=edge)
        if v['q_start'] == 1 and v['q_idle'] == 1:
            if owner is not None or v['qdir'] != 1 or v['wtrans'] != wtrans:
                raise ValueError('Wrong quant mode or overlapping legacy owner')
            opcode = v['q_instr'] & 255
            if opcode not in (0x21, 0x24):
                raise ValueError('Unexpected quant opcode')
            resource = 's' if opcode == 0x21 else 'z'
            sequence = v['q_work_seq'] - 1
            if not 0 <= sequence < (k // mxu) * (n // mxu):
                raise ValueError('Command outside fixed N-fast shape')
            command_identity = (job['host_generation'], resource, sequence + 1)
            if command_identity in accepted_commands:
                raise ValueError('Quant command identity accepted more than once')
            if sequence and (job['host_generation'], resource, sequence) not in accepted_commands:
                raise ValueError('Quant command order is not fixed N-fast')
            accepted_commands.add(command_identity)
            micro_k, micro_n = divmod(sequence, n // mxu)
            expected_row, expected_col = micro_k * mxu, (micro_n * mxu) // 32
            if (v['q_bounds'], v['q_seg'], v['q_source_stride'], v['q_dest_stride']) != (mxu, 2, 8, 2):
                raise ValueError('QROW descriptor stride/segment contract differs')
            if v['q_instr'] >> 8 != mxu * 2:
                raise ValueError('QROW byte count differs')
            source = v['q_rs2_data']
            candidates = [load for (r, addr), load in loads.items()
                          if r == resource and addr <= source < addr + load['rows'] * 8]
            if len(candidates) != 1:
                raise ValueError('Source lacks unique completed external DMA load')
            load = candidates[0]
            local_row, local_byte = divmod(source - load['lmem_base'], 8)
            tensor_byte = load['tensor_base'] - job[resource + '_base'] + local_row * (n // 32) * 2 + local_byte
            row, col_byte = divmod(tensor_byte, (n // 32) * 2)
            if (row, col_byte // 2) != (expected_row, expected_col) or col_byte % 2:
                raise ValueError('DMA source mapping disagrees with fixed N-fast identity')
            owner = dict(resource=resource, opcode=opcode, epoch=epoch,
                         host_generation=job['host_generation'], entry_id=job['entry_id'],
                         work_seq=v['q_work_seq'], bank=(v['q_flags'] >> 1) & 1,
                         row=row, col=col_byte // 2, source_lmem=source,
                         destination=v['q_rs1_data'], q_accept_edge=edge,
                         load_complete_edge=load['complete_edge'], install_index=0,
                         lane_requests=[0] * lane_count)
        for lane in range(lane_count):
            prefix = f'lane{lane}_'
            if v[prefix + 'req_valid'] == 1 and v[prefix + 'req_ready'] == 1:
                if owner is None:
                    raise ValueError('Physical lane request without quant owner')
                segment = owner['lane_requests'][lane]
                if segment >= mxu:
                    raise ValueError('Extra QROW physical segment request')
                scalar_address = owner['source_lmem'] + segment * 8
                wide_address = scalar_address // width * width
                lane_address = wide_address + lane * 8
                wide_mask = 3 << (scalar_address % width)
                lane_mask = (wide_mask >> (lane * 8)) & 255
                if (v[prefix + 'req_data_addr'] * 8, v[prefix + 'req_data_byteen']) != (lane_address, lane_mask):
                    raise ValueError('QROW physical address/byteen differs from expected strided scalar')
                tag = v[prefix + 'req_data_tag_value']
                key = lane, tag
                if key in pending:
                    raise ValueError('Physical lane tag reused before response')
                pending[key] = dict(resource=owner['resource'], epoch=epoch,
                                    host_generation=job['host_generation'], entry_id=job['entry_id'],
                                    work_seq=owner['work_seq'], bank=owner['bank'], lane=lane,
                                    segment=segment, row=owner['row'] + segment, col=owner['col'],
                                    byteen=lane_mask, tag=tag, address=lane_address, request_edge=edge)
                owner['lane_requests'][lane] += 1
            if v[prefix + 'rsp_valid'] == 1 and v[prefix + 'rsp_ready'] == 1:
                key = lane, v[prefix + 'rsp_data_tag_value']
                if key not in pending:
                    raise ValueError('Physical response without reserved read')
                response = pending.pop(key)
                response.update(actual=words(v[prefix + 'rsp_data_data'], 4), response_edge=edge)
                physical.append(response)
        for resource in ('s', 'z'):
            if v[resource + '_write'] != 1:
                continue
            if owner is None or owner['resource'] != resource:
                raise ValueError('Unowned QROW register install')
            if (v['owner_bank'], v['owner_seq'], v['owner_op']) != (owner['bank'], owner['work_seq'], owner['opcode']):
                raise ValueError('Node owner/generation mismatch')
            if (v[resource + '_req_valid'], v[resource + '_req_ready'], v[resource + '_bank']) != (1, 1, owner['bank']):
                raise ValueError('Actual register install handshake/bank mismatch')
            segment = owner['install_index']
            destination = owner['destination'] + segment * 2
            mask = 3 << (destination % width)
            address = destination // width * width
            if (v[resource + '_req_data_byteen'], v[resource + '_req_data_addr']) != (mask, address):
                raise ValueError('QROW installed address/byteen does not match scalar segment')
            record = {key: value for key, value in owner.items() if key != 'lane_requests'}
            record.update(row=owner['row'] + segment, segment=segment, byteen=mask,
                          address=address, actual=words(v[resource + '_req_data_data'], mxu),
                          edge=edge, time=time)
            installs.append(record)
            owner['install_index'] += 1
            if owner['install_index'] == mxu:
                if owner['lane_requests'] != [mxu] * lane_count:
                    raise ValueError('Install completed without all physical source requests')
                owner = None
    if owner is not None or external is not None or pending:
        raise ValueError('Capture ends with outstanding transport')
    expected_installs = repetitions * 2 * (k // mxu) * (n // mxu) * mxu
    if len(jobs) != repetitions or len(installs) != expected_installs or len(physical) != expected_installs * lane_count:
        raise ValueError(f'Incomplete coverage jobs={len(jobs)} installs={len(installs)} physical={len(physical)} expected={expected_installs}')
    required_commands = {(generation, resource, sequence) for generation in range(repetitions)
                         for resource in ('s', 'z') for sequence in range(1, (k // mxu) * (n // mxu) + 1)}
    if accepted_commands != required_commands:
        raise ValueError('Accepted command identity coverage incomplete')
    for name, records in [('install', installs), ('physical', physical)]:
        mismatch = errors(records)
        if mismatch:
            raise ValueError(f'{name} mismatches {len(mismatch)}: {mismatch[:8]}')
    return jobs, installs, physical


def controls(installs, physical, width):
    lookup = {(r['host_generation'], r['resource'], r['work_seq'], r['segment']): r for r in installs}
    commands = {}
    for record in installs:
        commands.setdefault((record['host_generation'], record['resource'], record['work_seq']), []).append(record)
    results = []
    for resource in ('s', 'z'):
        target = next(r for r in installs if r['host_generation'] == 1 and r['resource'] == resource and r['segment'] == 5)
        stale = lookup[(0, resource, target['work_seq'], target['segment'])]
        active_element = (target['byteen'].bit_length() - 1) // 2
        for name, lo, length in [('element_2B', active_element, 1),
                                 ('physical_lane_chunk_8B', (active_element // 4) * 4, 4),
                                 (f'wide_beat_{width}B', 0, width // 2)]:
            changed = dict(target, actual=list(target['actual']))
            changed['actual'][lo:lo + length] = stale['actual'][lo:lo + length]
            mismatch = errors([changed])
            if len(mismatch) != 1:
                raise AssertionError('Masked QROW payload fault was not detected at its active element')
            results.append(dict(resource=resource, fault=name, replaced_payload_elements=length,
                                detected_active_elements=1, byteen=target['byteen'], host_generation=1))
        key = 1, resource, target['work_seq']
        bad_command = [dict(r, actual=list(lookup[(0, resource, r['work_seq'], r['segment'])]['actual']))
                       for r in commands[key]]
        mismatch = errors(bad_command)
        if len(mismatch) != width // 2:
            raise AssertionError('Whole QROW stale command not detected in every masked segment')
        results.append(dict(resource=resource, fault='stale_command_all_segments',
                            command_installs=len(bad_command), detected_active_elements=len(mismatch)))
        target_lane = next(r for r in physical if r['resource'] == resource and r['host_generation'] == 1 and r['byteen'])
        previous_lane = next(r for r in physical if r['resource'] == resource and r['host_generation'] == 0
                             and (r['work_seq'], r['segment'], r['lane']) == (target_lane['work_seq'], target_lane['segment'], target_lane['lane']))
        if len(errors([dict(target_lane, actual=list(previous_lane['actual']))])) != 1:
            raise AssertionError('Actual tagged physical lane payload fault missed')
        results.append(dict(resource=resource, fault='actual_physical_response_lane_8B', detected_active_elements=1))
    detectable = equivalent = 0
    for (generation, resource, work_seq), command in commands.items():
        previous = commands.get((generation, resource, work_seq - 1))
        if previous is None:
            continue
        changed = [dict(target, actual=list(stale['actual'])) for target, stale in zip(command, previous)]
        if errors(changed):
            detectable += 1
        else:
            # Same QROW group loaded for adjacent N slices is a real semantic
            # equivalence, not a successful negative control.
            if [(r['row'], r['col']) for r in command] != [(r['row'], r['col']) for r in previous]:
                raise AssertionError('Unexpected masked stale-command equivalence')
            equivalent += 1
    generations_tested = 0
    for (generation, resource, work_seq), command in commands.items():
        if generation == 0:
            continue
        previous = commands[(generation - 1, resource, work_seq)]
        changed = [dict(target, actual=list(stale['actual'])) for target, stale in zip(command, previous)]
        if len(errors(changed)) != len(command):
            raise AssertionError('Stale previous-job command escaped immutable generation oracle')
        generations_tested += 1
    return {'representative_controls': results,
            'immediately_previous_same_job_command': {'detectable': detectable, 'semantically_equivalent': equivalent,
                                                     'equivalent_cases_are_not_counted_as_detected': True},
            'previous_job_generation_stale_commands': {'attempted': generations_tested, 'detected': generations_tested,
                                                      'every_active_segment_detected': True},
            'scope': 'copied captured payloads with address/byteen/command metadata retained; no live RTL fault injection'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, default=base.ROOT / 'agent-tasks/gemm-naive-improve-baseline/p0-baseline/naive-qrow-wt1-tagged-repeat3')
    parser.add_argument('--prefix', type=Path, default=base.ROOT / 'agent-tasks/gemm-naive-improve-baseline/p0-install-naive-qrow-repeat3')
    args = parser.parse_args()
    manifest_path = args.run / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('returncode') != 0 or not re.search(r'^PASSED$', (args.run / 'wrapper.log').read_text(), re.M):
        raise ValueError('Only finalized passing captures may be analyzed')
    for name in (base.HEADER, 'tests/regression/fpint_gemm_ffn_hw_naive/main.cpp'):
        if manifest['source_hashes'][name] != base.sha(base.ROOT / name):
            raise ValueError('Current oracle/host generation mapping differs from captured source')
    mxu_override = re.search(r'-DMXU_COL=(\d+)', manifest['configs'])
    if mxu_override:
        mxu = int(mxu_override.group(1))
    else:
        config_header = base.ROOT / 'hw/rtl/VX_config.vh'
        if manifest['source_hashes']['hw/rtl/VX_config.vh'] != base.sha(config_header):
            raise ValueError('Resolved default geometry source differs from captured config')
        mxu = int(re.search(r'^`define MXU_COL (\d+)\b', config_header.read_text(), re.M).group(1))
    width = mxu * 2
    wave = args.run / 'wave.fsdb'
    wave_hash = base.sha(wave)
    snapshot = args.prefix.with_name(args.prefix.name + '-snapshot.json')
    if snapshot.exists():
        captured = json.loads(snapshot.read_text())
        if captured['wave_sha256'] != wave_hash:
            raise ValueError('Waveform changed since snapshot')
        signals = captured['signals']
    else:
        signals = capture(wave, paths_for(width))
        snapshot.write_text(json.dumps(dict(wave=str(wave.resolve()), wave_sha256=wave_hash, signals=signals)) + '\n')
    jobs, installs, physical = check(signals, manifest, width)
    result = dict(status='pass', geometry=dict(m=manifest['m'], k=64, n=64, qdir=1, wtrans=manifest['wtrans'], tagged=True, mxu=mxu),
                  jobs=jobs, reset_between_jobs=True, no_reset_lifecycle_proven=False,
                  installs=len(installs), active_installed_elements=len(installs),
                  physical_lane_responses=len(physical), active_physical_lane_responses=sum(bool(r['byteen']) for r in physical),
                  payload_mismatches=0, physical_mismatches=0,
                  command_count=len({(r['host_generation'], r['resource'], r['work_seq']) for r in installs}),
                  unique_tensor_elements_per_job_resource={str(g): {resource: len({(r['row'], r['col']) for r in installs
                          if r['host_generation'] == g and r['resource'] == resource}) for resource in ('s', 'z')} for g in range(manifest['repeat'])},
                  actual_install_byte_masks=sorted({r['byteen'] for r in installs}),
                  banks=sorted({r['bank'] for r in installs}),
                  wave_sha256=wave_hash, manifest_sha256=base.sha(manifest_path),
                  vector_sha256=base.sha(base.ROOT / base.HEADER), controls=controls(installs, physical, width),
                  installed_records=installs, physical_records=physical,
                  limitations=['masked-out response/install data are not semantically checked',
                               'post-edge register arrays are not independently read back',
                               'faults operate on captured payload copies, not a live simulation',
                               'current N/K dimensions are multiples of MXU; arbitrary N/K tails remain pending',
                               'invocations include RTL resets, not no-reset lifecycle evidence'])
    output = args.prefix.with_name(args.prefix.name + '-results.json')
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('installed_records', 'physical_records')}, indent=2))

if __name__ == '__main__':
    main()
