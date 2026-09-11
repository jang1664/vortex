#!/usr/bin/env python3
"""Compare accepted RTL commands with independent frozen Input geometry.

Expected values never use observed descriptor data. The frozen canonical
provides Input identities/addresses; external-copy and metadata formulas here
extend that oracle to the complete real-command stream.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / "agent-tasks/gemm-naive-improve-baseline/p0-contract.py"
spec = importlib.util.spec_from_file_location("frozen_contract", CONTRACT)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
BASE = 0x1ffc00000
DRAM = [0x180000000, 0x190000000, 0x1a0000000, 0x1b0000000, 0x1c0000000]


def blank():
    return dict(instr=0, rs1=0, rs2=0, rd=0, rs1_data=0, rs2_data=0,
                stride=0, bound=0, flags=0, eff_mt=0, groups_eff=0, work_seq=0,
                naive_final_base=0, naive_final_stride=0, naive_terminal=0,
                naive_source_buffer=0, naive_source_generation=0,
                dma_priority=0, dma_max_chunk_log2p1=0,
                waits=[[0, 0, 0] for _ in range(5)],
                input_admit_waits=[[0, 0, 0] for _ in range(4)],
                writer_wait=[0, 0, 0], prepare=[0, 0, 0, 0, 0, 0],
                notify=[0, 0, 0, 0])


def expected(cfg):
    m, k, n, mxu, qr, wt = (cfg[x] for x in ("m", "k", "n", "mxu", "qrow", "wtrans"))
    ms, ns = cfg["m_start"], cfg["n_start"]
    om, on, ok = cfg["orig_m"], cfg["orig_n"], cfg["orig_k"]
    inputs = contract.stream(m, k, n, mxu, qr, wt)
    regions = contract.regions(qr)
    tiles = {}
    for item in inputs:
        tiles.setdefault(item["dma_tile"], []).append(item)
    total_tiles = len(tiles)
    ceiling = lambda a, b: (a + b - 1) // b
    commands = []

    def load(d):
        c = tiles[d][0]
        bank, generation = c["source_bank"], c["source_generation"]
        mt, nt, kt = c["mt"], c["nt"], c["kt"]
        rows, cols, kk = min(128, m-mt*128), min(128, n-nt*128), min(128, k-kt*128)
        addresses = [DRAM[0] + ((ms+mt*128)*ok+kt*128)*2,
                     DRAM[1] + ((ns+nt*128)*ceiling(ok, 2)+kt*64 if wt
                                else kt*128*ceiling(on, 2)+(ns+nt*128)//2)]
        qoffset = (kt*128*ceiling(on, 32)+(ns+nt*128)//32 if qr
                   else (kt*128//32)*on+ns+nt*128)*2
        addresses.extend([DRAM[3]+qoffset, DRAM[4]+qoffset])
        sizes = [rows*kk*2, cols*ceiling(kk, 2) if wt else kk*ceiling(cols, 2)]
        sizes.extend([kk*ceiling(cols, 32)*2 if qr else ceiling(kk, 32)*cols*2]*2)
        for member, name in enumerate(("I", "W", "SC", "ZP")):
            x = blank()
            x.update(instr=(sizes[member] << 4)|1, rd=member,
                     rs1_data=BASE+regions[f"{name}{bank}"][0], rs2_data=addresses[member],
                     flags=((generation & 127) << 1)|bank,
                     work_seq=d*(128//mxu)**2+1,
                     naive_source_buffer=bank, naive_source_generation=generation)
            if member == 0:
                x.update(rs1=mt, rs2=kt)
            elif member == 1:
                x.update(rs1=kt, rs2=nt)
            else:
                x.update(rs2=nt, groups_eff=kk if qr else ceiling(kk, 32))
            if d >= 2:
                x["waits"][0] = [1, 22 if bank else 21, generation-1]
            commands.append(x)

    load(0)
    if total_tiles > 1:
        load(1)
    for d, local in tiles.items():
        for c in local:
            rb, sb, sg, seq = c["ordinal"] % 2, c["source_bank"], c["source_generation"], c["work_seq"]
            previous = c["ordinal"]//2
            for child, op in enumerate((5, 6, 10, 7)):
                x = blank()
                x.update(work_seq=seq, naive_source_buffer=sb, naive_source_generation=sg)
                x["waits"][0] = [1, 5 if sb else 0, sg]
                x["prepare"] = [1, 1, 16 if child in (0, 3) else 8, 1, 5 if sb else 0, sg]
                cols = c["columns"]
                if child == 0:
                    x.update(instr=((cols*(mxu//2) if wt else mxu*ceiling(cols, 2)) << 4)|op,
                             rs1_data=rb, rs2_data=BASE+c["weight_base"],
                             flags=(wt << 1)|rb, bound=cols if wt else mxu,
                             stride=64, groups_eff=cols)
                    rid, consume = (6 if rb else 1), (16 if rb else 15)
                elif child in (1, 2):
                    segments = mxu if qr else ceiling(mxu, 32)
                    useful = ceiling(cols, 32)*2 if qr else cols*2
                    x.update(instr=(segments*useful << 4)|op,
                             rs1_data=((2 if child == 2 else 0)+rb)*mxu*2,
                             rs2_data=BASE+c["zero_base" if child == 2 else "scale_base"],
                             flags=(qr << 2)|(rb << 1), bound=segments,
                             stride=8 if qr else 256, groups_eff=useful)
                    rid = (14 if rb else 12) if child == 2 else (13 if rb else 11)
                    consume = (20 if rb else 19) if child == 2 else (18 if rb else 17)
                else:
                    x.update(instr=(c["rows"] << 4)|op,
                             rs1_data=BASE+c["psum_base"], rs2_data=BASE+c["input_base"],
                             stride=mxu*4, bound=c["rows"], eff_mt=c["rows"], groups_eff=cols,
                             naive_final_base=BASE+c["final_base"], naive_final_stride=256,
                             naive_terminal=int(c["terminal"]),
                             flags=(qr << 6)|(int(c["terminal"]) << 5)|(int(c["accumulate"]) << 4)
                                   |(int(c["last_k"]) << 3)|rb*7)
                    x["input_admit_waits"] = [[1, 6 if rb else 1, seq],
                                              [1, 13 if rb else 11, seq],
                                              [1, 14 if rb else 12, seq],
                                              [1, 4, c["owner"]-1]]
                    x["notify"] = [1, 8 if c["terminal"] else 3, 0, 1]
                if child != 3:
                    x["notify"] = [1, rid, 1, seq]
                    if previous:
                        x["writer_wait"] = [1, consume, previous]
                commands.append(x)
        last = local[-1]
        if last["terminal"]:
            x = blank()
            rows, cols = last["rows"], min(128, n-last["nt"]*128)
            x.update(instr=(rows*cols*2 << 4)|2, rd=4, rs1=last["mt"], rs2=last["nt"],
                     rs1_data=DRAM[2]+((ms+last["mt"]*128)*on+ns+last["nt"]*128)*2,
                     rs2_data=BASE+regions["OBUF"][0], work_seq=last["work_seq"],
                     naive_source_buffer=last["source_bank"], naive_source_generation=last["source_generation"])
            x["waits"][0] = [1, 8, last["owner"]]
            x["notify"] = [1, 4, 0, 1]
            commands.append(x)
        if d+2 < total_tiles:
            load(d+2)
    closures = [[d % 2, d//2+1, len(items)] for d, items in tiles.items()]
    return commands, closures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    cfg = json.loads(args.config.read_text())
    want, closures = expected(cfg)
    got, actual_closures = [], []
    for line in args.trace.read_text().splitlines():
        event = json.loads(line)
        if "closure" in event:
            actual_closures.append(event["closure"])
        else:
            got.append(event)
    assert len(got) == len(want), ("command count", len(got), len(want))
    for ordinal, (actual, expected_item) in enumerate(zip(got, want)):
        different = {k: (actual.get(k), value) for k, value in expected_item.items()
                     if actual.get(k) != value}
        assert not different, ("descriptor mismatch", ordinal, different)
        assert actual.keys() == expected_item.keys(), ("unknown descriptor fields", ordinal)
    assert actual_closures == closures, ("producer closure", actual_closures, closures)
    print("TEST PASSED canonical real command stream", json.dumps(dict(
        config=cfg, commands=len(got), closures=len(closures),
        contract_sha256=hashlib.sha256(CONTRACT.read_bytes()).hexdigest(),
        trace_sha256=hashlib.sha256(args.trace.read_bytes()).hexdigest())))


if __name__ == "__main__":
    main()
