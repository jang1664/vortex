#!/usr/bin/env python3
"""Reproducible cycle accounting from fsdb_cli's clock-sampled signal cache."""
from collections import Counter, deque
import json
from pathlib import Path

TASK = Path(__file__).resolve().parent


def stats(values):
    indices = [i for i, value in enumerate(values) if value]
    first, last = (indices[0], indices[-1]) if indices else (None, None)
    span = last - first + 1 if indices else 0
    return dict(count=sum(values), active_cycles=len(indices), first=first,
                last=last, span=span, peak=max(values),
                gaps=dict(sorted(Counter(b-a-1 for a, b in zip(indices, indices[1:])).items())))


def analyze(channels, m):
    case = TASK / f'ch{channels}' / f'm{m}'
    sample = json.loads((case / 'sampled.json').read_text())
    d, n = sample['data'], sample['cycles']
    # Command payload is allowed to be X while its valid is low.
    assert all(None not in values for key, values in d.items()
               if key != 'weight_command_total_beats')
    assert all(beats is not None for valid, beats in
               zip(d['weight_command_enqueue'], d['weight_command_total_beats']) if valid)
    assert d['total'] == list(range(n))

    def handshake(prefix):
        return [int(bool(v and r)) for v, r in zip(d[prefix+'_valid'], d[prefix+'_ready'])]

    def aggregate(arrays):
        return [sum(values) for values in zip(*arrays)]

    result = dict(channels=channels, M=m, cycles=n, start_ps=sample['start_ps'],
                  end_ps=sample['end_ps'], period_ps=sample['period_ps'])
    result['streams'] = {key: stats(d[key]) for key in
                         ['input_fire', 'compute_fire', 'mxu_ready_weight',
                          'computing', 'any_dma', 'hbm_busy']}
    assert sum(d['input_fire']) == sum(d['compute_fire']) == 64*m
    assert sum(d['mxu_ready_weight']) == 512
    axi = {kind: aggregate([handshake(f'axi{p}_{kind}') for p in range(channels)])
           for kind in ['ar', 'r', 'aw', 'w', 'b']}
    result['axi'] = {kind: stats(values) for kind, values in axi.items()}
    result['axi']['read_peak_utilization_pct'] = 100*sum(axi['r'])/(channels*n)
    result['axi']['read_bytes'] = 64*sum(axi['r'])
    result['axi']['write_bytes'] = 64*sum(axi['w'])
    result['axi']['r_backpressure_port_cycles'] = sum(
        bool(v and not r) for p in range(channels)
        for v, r in zip(d[f'axi{p}_r_valid'], d[f'axi{p}_r_ready']))
    lengths, first_response_latencies = Counter(), Counter()
    for p in range(channels):
        pending = deque()
        ars, rs = handshake(f'axi{p}_ar'), handshake(f'axi{p}_r')
        # VX_dma_engine fixes ar_id=0; responses are ordered within each port.
        for i in range(n):
            if ars[i]:
                beats = d[f'axi{p}_ar_len'][i]+1
                lengths[beats] += 1
                pending.append([i, beats, False])
            if rs[i]:
                assert pending, (p, i)
                request = pending[0]
                if not request[2]:
                    first_response_latencies[i-request[0]] += 1
                    request[2] = True
                request[1] -= 1
                if request[1] == 0:
                    pending.popleft()
        assert not pending
    result['axi']['ar_burst_beats_histogram'] = dict(sorted(lengths.items()))
    result['axi']['ar_to_first_r_cycles_histogram'] = dict(sorted(first_response_latencies.items()))

    physical = aggregate([d[f'bank{p}_sram_{kind}'] for p in range(channels)
                          for kind in ['read', 'write']])
    assert max(physical) <= channels
    result['tmem'] = dict(physical_accesses=stats(physical),
                          peak_utilization_pct=100*sum(physical)/(channels*n))
    bank_grants, bank_stalls = {}, {}
    for bit, name in enumerate(['hbm', 'i', 'w', 'sc', 'zp', 'o']):
        mask = 1 << bit
        bank_grants[name] = [sum(bool(d[f'bank{p}_request_valid'][i]
                                     & d[f'bank{p}_request_ready'][i] & mask)
                                  for p in range(channels)) for i in range(n)]
        bank_stalls[name] = [sum(bool(d[f'bank{p}_request_valid'][i] & mask
                                     and not d[f'bank{p}_request_ready'][i] & mask)
                                  for p in range(channels)) for i in range(n)]
    result['tmem']['ports'] = {name: dict(grants=sum(bank_grants[name]),
                                        stall_port_cycles=sum(bank_stalls[name]))
                                for name in bank_grants}
    result['tmem']['weight_conflict_winners'] = dict(Counter(
        d[f'bank{p}_request_valid'][i] & d[f'bank{p}_request_ready'][i]
        for i in range(n) for p in range(channels)
        if d[f'bank{p}_request_valid'][i] & 4 and not d[f'bank{p}_request_ready'][i] & 4))

    weight = d['mxu_ready_weight']
    # Every accepted bank-side Weight request appears at the GEMM sink exactly
    # five cycles later in these captures; no hidden sink-side serialization.
    assert bank_grants['w'][:-5] == weight[5:]
    assert sum(bank_grants['w']) == sum(weight) == 512
    assert not any(v and not r for v, r in zip(d['gemm_w_req_valid'], d['gemm_w_req_ready']))
    ws = stats(weight)
    indices = [i for i, v in enumerate(weight) if v]
    long_gaps = [(a+1, b-1) for a, b in zip(indices, indices[1:]) if b-a>10]
    assert len(long_gaps) == 1
    gap_first, gap_last = long_gaps[0]
    assert sum(weight[:gap_first]) == 384
    # The long empty-input interval maps back to a bank request-free interval.
    for i in range(gap_first-5, gap_last-5+1):
        assert all(not d[f'bank{p}_request_valid'][i] & 4 for p in range(channels))
    gap_size = gap_last-gap_first+1
    bank_wait = sum(bank_stalls['w'])
    assert ws['span'] == 512 + gap_size + bank_wait
    tail = n-ws['last']-1
    result['cycle_decomposition'] = dict(startup_to_first_weight=ws['first'],
        weight_beats=512, weight_bank_conflict_bubbles=bank_wait,
        weight_command_supply_gap=gap_size, tail_after_last_weight=tail)
    assert sum(result['cycle_decomposition'].values()) == n
    enqueue = [i for i, v in enumerate(d['weight_command_enqueue']) if v]
    assert len(enqueue) == 64
    assert sum(d['weight_command_total_beats'][i] for i in enqueue) == 512
    result['weight_gap'] = dict(first=gap_first, last=gap_last,
        next_command_enqueue=next(i for i in enqueue if i >= gap_first),
        empty_command_queue_cycles=sum(v == 0 for v in d['weight_queue_cmd_occupancy'][gap_first:gap_last+1]))

    result['overlap'] = {}
    for busy in ['hbm_busy', 'any_dma']:
        for consumer in ['computing', 'mxu_ready_weight']:
            result['overlap'][busy+'_and_'+consumer] = sum(bool(a and b)
                                                       for a, b in zip(d[busy], d[consumer]))
    result['overlap']['axi_r_active_and_weight_fire'] = sum(bool(a and b) for a, b in zip(axi['r'], weight))
    result['overlap']['axi_r_beats_during_weight_span'] = sum(axi['r'][ws['first']:ws['last']+1])
    pending = [bool(a and b) for a, b in zip(d['prealigner_out_valid'], d['pre_meta_valid_out'])]
    result['compute_wait'] = dict(pending_cycles=sum(pending),
        weight_not_ready=sum(p and not w for p, w in zip(pending, d['weight_ready'])),
        zero_not_ready=sum(p and not z for p, z in zip(pending, d['zero_ready'])),
        no_tree_credit=sum(p and not c for p, c in zip(pending, d['tree_credit_q'])))
    (case / 'analysis.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    results = [analyze(channels, m) for channels in [8, 4] for m in [1, 4]]
    (TASK / 'summary.json').write_text(json.dumps(results, indent=2)+'\n')
    for result in results:
        print(f"ch{result['channels']} M{result['M']}: {result['cycles']} cycles; "
              f"{result['cycle_decomposition']}")
        print('  AR->firstR', result['axi']['ar_to_first_r_cycles_histogram'],
              'TMEM utilization', round(result['tmem']['peak_utilization_pct'], 2))
