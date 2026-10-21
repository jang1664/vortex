#!/usr/bin/env python3
"""Count sampled AXI handshakes in a FSDB, attributing weight reads to DMA tiles."""
import argparse
from collections import defaultdict, deque
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[4] / 'tools'))
from fsdb_cli.api import report


def number(value):
    return None if not value or any(c in value.lower() for c in 'xz') else int(value, 2)


def software_address(address):
    # Inverse of VX_mem_remap: 34 address bits, 32 banks, 4 ports, 64-byte lines.
    bank, offset = address >> 29, address & ((1 << 29) - 1)
    block = (((offset >> 6) * 8 + bank % 8) * 4 + bank // 8)
    return block * 64 + offset % 64


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fsdb', type=Path)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--k', type=int, required=True)
    parser.add_argument('--n', type=int, required=True)
    parser.add_argument('--bits', type=int, choices=(4, 16), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--partial', action='store_true',
                        help='Capture intentionally stops after initial DMA tiles')
    args = parser.parse_args()
    log = args.log.read_text()
    weight_base = int(re.search(r'weight_base=(0x[0-9a-fA-F]+)', log)[1], 16)
    row_bytes = args.n * args.bits // 8
    tile_row_bytes = 128 * args.bits // 8
    weight_end = weight_base + args.k * row_bytes
    paths = {'clk': '/tb_vcs_xrtsim/ap_clk'}
    widths = {'arvalid': '', 'arready': '', 'araddr': '[63:0]', 'arid': '[31:0]',
              'arlen': '[7:0]', 'arsize': '[2:0]', 'rvalid': '', 'rready': '',
              'rid': '[31:0]', 'rlast': ''}
    for port in range(4):
        for name, width in widths.items():
            paths[f'{name}{port}'] = f'/tb_vcs_xrtsim/m_axi_mem_{name}[{port}]{width}'
    rep = report(str(args.fsdb), list(paths.values()))
    if rep.time_unit != '1ps':
        raise ValueError(f'Unexpected FSDB time unit: {rep.time_unit}')
    names = {path: key for key, path in paths.items()}
    columns = [names[path] for path in rep.signal_names]
    state = {}
    outstanding = defaultdict(deque)
    tiles = {}
    totals = {name: [0] * 4 for name in ('ar', 'r', 'ar_stall', 'r_backpressure')}
    unmatched_responses = 0

    def tile_for(address):
        logical = software_address(address)
        if not weight_base <= logical < weight_end:
            return None
        offset = logical - weight_base
        key = f'k{offset // row_bytes // 128}_n{offset % row_bytes // tile_row_bytes}'
        if key not in tiles:
            tiles[key] = {'ar_beats': [0] * 4, 'r_beats': [0] * 4,
                          'ar_stall_cycles': [0] * 4, 'r_backpressure_cycles': [0] * 4,
                          'first_ar_ps': None, 'last_r_ps': None,
                          'r_active_cycles': 0, 'r_multiport_cycles': 0}
        return key

    # Evaluate values strictly BEFORE each rising edge. FSDB values at that edge
    # include NBA updates and must not be counted as the accepted transaction.
    for row in rep.data_rows:
        time = int(row[0])
        changes = {key: number(v) for key, v in zip(columns, row[1:]) if v != ''}
        if changes.get('clk') == 1 and state.get('clk') == 0:
            returned = defaultdict(set)
            for port in range(4):
                if state.get(f'arvalid{port}') == 1:
                    address = state[f'araddr{port}']
                    tile = tile_for(address)
                    if state.get(f'arready{port}') == 1:
                        totals['ar'][port] += 1
                        size = 1 << state[f'arsize{port}']
                        if size != 64:
                            raise AssertionError('This profile expects 64-byte AXI beats')
                        beats = state[f'arlen{port}'] + 1
                        tags = []
                        for beat in range(beats):
                            t = tile_for(address + beat * size)
                            tags.append(t)
                            if t is not None:
                                tiles[t]['ar_beats'][port] += 1
                                if tiles[t]['first_ar_ps'] is None:
                                    tiles[t]['first_ar_ps'] = time
                        outstanding[(port, state[f'arid{port}'])].append(deque(tags))
                    else:
                        totals['ar_stall'][port] += 1
                        if tile is not None:
                            tiles[tile]['ar_stall_cycles'][port] += 1
                if state.get(f'rvalid{port}') == 1:
                    queue = outstanding[(port, state[f'rid{port}'])]
                    tile = queue[0][0] if queue else None
                    if state.get(f'rready{port}') == 1:
                        totals['r'][port] += 1
                        if not queue:
                            unmatched_responses += 1
                        else:
                            queue[0].popleft()
                            if bool(state[f'rlast{port}']) != (not queue[0]):
                                raise AssertionError('RLAST disagrees with ARLEN')
                            if not queue[0]:
                                queue.popleft()
                        if tile is not None:
                            tiles[tile]['r_beats'][port] += 1
                            tiles[tile]['last_r_ps'] = time
                            returned[tile].add(port)
                    else:
                        totals['r_backpressure'][port] += 1
                        if tile is not None:
                            tiles[tile]['r_backpressure_cycles'][port] += 1
            for tile, ports in returned.items():
                tiles[tile]['r_active_cycles'] += 1
                tiles[tile]['r_multiport_cycles'] += len(ports) > 1
        state.update(changes)
    for data in tiles.values():
        if data['first_ar_ps'] is not None and data['last_r_ps'] is not None:
            data['read_window_cycles'] = (data['last_r_ps'] - data['first_ar_ps']) // 10000 + 1
    result = {'fsdb': str(args.fsdb.resolve()), 'k': args.k, 'n': args.n,
              'bits': args.bits, 'weight_base': hex(weight_base),
              'partial_capture': args.partial,
              'weight_bytes_expected': args.k * row_bytes, 'totals': totals,
              'unmatched_responses': unmatched_responses,
              'outstanding_transactions': sum(len(q) for q in outstanding.values()),
              'tiles': tiles}
    result['weight_bytes_observed'] = 64 * sum(sum(t['r_beats']) for t in tiles.values())
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'tiles'}))
    for key, data in list(tiles.items())[:4]:
        print(key, json.dumps(data))
    if unmatched_responses or result['outstanding_transactions']:
        raise AssertionError('AXI request/response accounting incomplete')
    if not args.partial and result['weight_bytes_observed'] != result['weight_bytes_expected']:
        raise AssertionError('Weight payload accounting differs from matrix size')


if __name__ == '__main__':
    main()
