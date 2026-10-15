#!/usr/bin/env python3
"""Static budget/bank audit for the selected TH16 FPFP prototype configs."""
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIGS = [
    "naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh",
    "naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3.sh",
]


def audit(name, overrides=None):
    text = (ROOT / "configs" / name).read_text()
    defines = dict(re.findall(r"-D(\w+)=(\d+)\b", text))
    defines.update(overrides or {})
    capacity = int(defines["LMEM_SIZE"])
    banks = int(defines["LMEM_NUM_BANKS"])
    ports = int(defines["LMEM_NUM_PORTS"])
    mxu = int(defines["MXU_COL"])
    rows = int(defines["MXU_ROW"])
    assert all(dim > 0 and dim & (dim - 1) == 0 for dim in (rows, mxu))
    mt = kt = nt = 128
    buffers = []
    offset = 0
    for label, size in [
        ("A0", mt * kt * 2), ("A1", mt * kt * 2),
        ("B0", kt * nt * 2), ("B1", kt * nt * 2),
        ("C", mt * nt * 2), ("PSUM_reserved", mt * nt * 4),
    ]:
        offset = (offset + 63) & ~63
        buffers.append({"name": label, "begin": offset, "end": offset + size})
        offset += size
    assert offset <= capacity
    assert all(a["end"] <= b["begin"] for a, b in zip(buffers, buffers[1:]))
    word_bytes = 8
    per_bank_words = capacity // (banks * word_bytes)
    assert capacity % (banks * word_bytes) == 0
    max_bank_word = max((addr // word_bytes) // banks for addr in range(0, offset, word_bytes))
    assert max_bank_word < per_bank_words

    # Mirror get_acc_mem_idx/depth_addr; the stored vector width is MXU_COL.
    acc_depth = int(defines["GEMM_ACC_MEM_DEPTH"])
    psum_row_bytes = mxu * 4
    acc_total = acc_depth * psum_row_bytes * 4
    acc_addr_bits = (acc_total - 1).bit_length()
    bank_addr_bits = acc_addr_bits - 2
    bank_word_bits = (psum_row_bytes - 1).bit_length()
    acc_locations = set()
    max_depth = 0
    for n0 in range(0, nt, mxu):
        for row in range(mt):
            addr = n0 * mt * 4 + row * mxu * 4
            bank = (((addr >> (bank_addr_bits + 1)) & 1) << 1) | ((addr >> bank_word_bits) & 1)
            bank_addr = ((addr >> (bank_word_bits + 1)) & ((1 << (bank_addr_bits - bank_word_bits)) - 1)) << bank_word_bits
            depth = bank_addr >> bank_word_bits
            assert (bank, depth) not in acc_locations
            acc_locations.add((bank, depth))
            max_depth = max(max_depth, depth)
    assert max_depth < acc_depth

    loads = []
    for wload in (1, 4):
        lanes = mxu * wload * 2 // word_bytes
        assert lanes <= ports
        # Current ordinary row-major LMEM B tile: row stride = NT*2.
        requests = Counter((r * nt * 2 // word_bytes + c) % banks
                           for r in range(wload) for c in range(mxu * 2 // word_bytes))
        loads.append({"wload": wload, "payload_bytes": mxu * wload * 2,
                      "request_lanes": lanes, "banks_touched": len(requests),
                      "max_requests_per_bank": max(requests.values())})
    return {"config": name, "capacity_bytes": capacity, "scratch_bytes": offset,
            "remaining_bytes": capacity - offset, "buffers_relative_to_lmem_base": buffers,
            "max_lmem_bank_word": max_bank_word, "physical_words_per_bank": per_bank_words,
            "acc_max_depth_index": max_depth, "acc_depth": acc_depth,
            "weight_groups": loads, "status": "PASS"}


if __name__ == "__main__":
    print(json.dumps({"assumptions": [
        "MT=KT=NT=128, LMEM offset zero, 64-byte alignment, 8-byte words",
        "Standalone naive app owns scratch; no concurrent allocator",
        "Default stack grows below LMEM_BASE=STACK_BASE; LSU routes only BASE..BASE+SIZE to LMEM",
        "Actual source config/build and runtime allocation must agree before simulation",
    ], "results": [audit(config) for config in CONFIGS]}, indent=2))
