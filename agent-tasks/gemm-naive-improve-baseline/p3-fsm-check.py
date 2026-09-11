#!/usr/bin/env python3
"""Compare actual FSM transcript with the frozen canonical microtile stream."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

TASK = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('frozen_contract', TASK / 'p0-contract.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
FIELDS = ('op work bank generation amount a1 a2 final final_stride stride bound rows groups flags '
          'notify_rid notify_value notify_set wait_valid wait_rid wait_target output_target '
          'writer_valid writer_rid writer_target terminal rd').split()
BASE = 0x100000000


def check(log, m, k, n, mxu, qrow, wtrans):
    commands = []
    closures = []
    raw = log.read_text()
    assert 'TEST PASSED metadata FSM' in raw
    for line in raw.splitlines():
        if line.startswith('CMD '):
            values = line.split()[1:]
            assert len(values) == len(FIELDS), line
            commands.append({key: int(value, 16 if key in ('a1', 'a2', 'final') else 10)
                             for key, value in zip(FIELDS, values)})
        if line.startswith('CLOSE '):
            closures.append(tuple(map(int, line.split()[1:])))
    expected = contract.stream(m, k, n, mxu, qrow, wtrans)
    local = [c for c in commands if c['op'] in (5, 6, 10, 7)]
    assert len(local) == 4 * len(expected)
    for ordinal, want in enumerate(expected):
        bank = ordinal % 2
        group = local[4*ordinal:4*ordinal+4]
        assert [c['op'] for c in group] == [5, 6, 10, 7]
        for got, field in zip(group, ('weight_base', 'scale_base', 'zero_base', 'input_base')):
            identity = (got['work'], got['bank'], got['generation'])
            assert identity == (want['work_seq'], want['source_bank'], want['source_generation']), (got, want)
            assert got['a2'] == BASE + want[field], (field, got, want)
            assert (got['wait_valid'], got['wait_rid'], got['wait_target']) == (
                1, 5 if want['source_bank'] else 0, want['source_generation'])
        for got, install_rid, consume_rid in zip(group[:3],
                (6 if bank else 1, 13 if bank else 11, 14 if bank else 12),
                (16 if bank else 15, 18 if bank else 17, 20 if bank else 19)):
            assert (got['notify_rid'], got['notify_value'], got['notify_set']) == (install_rid, want['work_seq'], 1)
            assert got['writer_valid'] == int(ordinal >= 2)
            if ordinal >= 2:
                assert (got['writer_rid'], got['writer_target']) == (consume_rid, ordinal // 2)
        weight = group[0]
        assert (weight['stride'], weight['bound'], weight['groups'], weight['flags']) == (
            64, want['columns'] if wtrans else mxu, want['columns'], wtrans*2+bank)
        assert weight['amount'] == (want['columns']*(mxu//2) if wtrans else mxu*((want['columns']+1)//2))
        for zero, got in enumerate(group[1:3]):
            segments = mxu if qrow else (mxu+31)//32
            useful = ((want['columns']+31)//32 if qrow else want['columns'])*2
            assert (got['bound'], got['groups'], got['amount'], got['stride']) == (
                segments, useful, segments*useful, 8 if qrow else 256)
            assert got['flags'] == qrow*4+bank*2
            assert got['a1'] == (zero*2+bank)*mxu*2
        got = group[3]
        assert (got['a1'], got['final'], got['stride'], got['final_stride']) == (
            BASE + want['psum_base'], BASE + want['final_base'], mxu*4, 256)
        assert (got['rows'], got['bound'], got['groups']) == (want['rows'], want['rows'], want['columns'])
        assert got['terminal'] == int(want['terminal'])
        assert got['output_target'] == want['owner'] - 1
        assert (got['notify_rid'], got['notify_value'], got['notify_set']) == (
            want['completion']['rid'], 1, 0)
        flags = (qrow << 6) | (int(want['terminal']) << 5) | (int(want['accumulate']) << 4)
        flags |= int(want['last_k']) << 3 | (7 if bank else 0)
        assert got['flags'] == flags
    tiles = {}
    for c in expected:
        tiles.setdefault(c['dma_tile'], []).append(c)
    assert closures == [(cs[0]['source_bank'], cs[0]['source_generation'], len(cs)) for cs in tiles.values()]
    loads = [c for c in commands if c['op'] == 1]
    assert len(loads) == 4 * len(tiles)
    rr = contract.regions(qrow)
    for tile, cs in tiles.items():
        first = cs[0]
        row0, col0, k0 = first['mt']*128, first['nt']*128, first['kt']*128
        rows, cols, nk = min(128,m-row0), min(128,n-col0), min(128,k-k0)
        dram = [0x110000000 + resource*0x1000000 for resource in range(5)]
        offsets = [2*(row0*k+k0),
                   col0*((k+1)//2)+k0//2 if wtrans else k0*((n+1)//2)+col0//2]
        quant_offset = 2*(k0*((n+31)//32)+col0//32) if qrow else 2*((k0//32)*n+col0)
        addresses = [dram[0]+offsets[0], dram[1]+offsets[1], dram[3]+quant_offset, dram[4]+quant_offset]
        quant_amount = nk*((cols+31)//32)*2 if qrow else ((nk+31)//32)*cols*2
        amounts = [rows*nk*2, cols*((nk+1)//2) if wtrans else nk*((cols+1)//2), quant_amount, quant_amount]
        for member, got in enumerate(loads[4*tile:4*tile+4]):
            assert (got['rd'], got['bank'], got['generation']) == (member, tile % 2, tile // 2 + 1)
            region = ('I', 'W', 'SC', 'ZP')[member] + str(tile % 2)
            assert got['a1'] == BASE + rr[region][0]
            assert (got['a2'], got['amount']) == (addresses[member], amounts[member])
            assert got['wait_valid'] == int(tile >= 2)
            if tile >= 2:
                assert (got['wait_rid'], got['wait_target']) == (21 + tile % 2, tile // 2)
    stores = [c for c in commands if c['op'] == 2]
    owners = sorted({c['owner'] for c in expected})
    assert len(stores) == len(owners)
    for got, owner in zip(stores, owners):
        first = next(c for c in expected if c['owner'] == owner)
        row0, col0 = first['mt']*128, first['nt']*128
        assert (got['wait_valid'], got['wait_rid'], got['wait_target']) == (1, 8, owner)
        assert (got['notify_rid'], got['notify_value'], got['notify_set']) == (4, 1, 0)
        assert got['a2'] == BASE + rr['OBUF'][0]
        assert got['a1'] == 0x112000000 + 2*(row0*n+col0)
        assert got['amount'] == min(128,m-row0)*min(128,n-col0)*2
    return dict(status='pass', microtiles=len(expected), loads=len(loads), stores=len(stores),
                source_closures=len(closures), transcript_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
                oracle_sha256=hashlib.sha256((TASK/'p0-contract.py').read_bytes()).hexdigest(),
                scope='Actual emitted command ordering, local operand/PSUM/final addresses, source owners, writer fences, O/G1/SRC_FREE and closure counts; not installed payload or physical execution')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('log', type=Path)
    for key, default in [('m',4),('k',512),('n',512),('mxu',16),('qrow',0),('wtrans',0)]:
        parser.add_argument('--'+key, type=int, default=default)
    args = parser.parse_args()
    print(json.dumps(check(**vars(args)), indent=2))
