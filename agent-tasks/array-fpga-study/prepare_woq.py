#!/usr/bin/env python3
"""Derive WoQ from a Fig.5 production snapshot without changing production RTL.

Only the flattened interface wrapper changes. All arithmetic, buffering, ACC
storage, pipeline and IP selection remain identical to the source snapshot.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

TOP = 'VX_gemm_unit_woq_top'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def derive_woq(flist, dest):
    flist, dest = Path(flist).resolve(), Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    paths = [Path(line) for line in flist.read_text().splitlines() if line.strip()]
    top = [p for p in paths if p.name == 'VX_gemm_unit_top.sv']
    if len(top) != 1:
        raise ValueError('Expected exactly one production VX_gemm_unit_top.sv')
    edits = [
        (r'\bmodule\s+VX_gemm_unit_top\b', 'module '+TOP),
        (r'(assign\s+gemm_unit_if\.gemm_unit_ctrl\.quant_dir\s*=)\s*ctrl_quant_dir\s*;', r"\1 1'b0;"),
        (r'(assign\s+w_lmem_bus_if\.req_data\.addr\s*=)\s*w_req_addr\s*;', r"\1 {w_req_addr[ADDR_WIDTH-1:2], 1'b0, w_req_addr[0]};"),
    ]
    rows, output = [], []
    for src in paths:
        dst = dest / (TOP+'.sv' if src == top[0] else src.name)
        content = src.read_text()
        if src == top[0]:
            for pattern, replacement in edits:
                content, count = re.subn(pattern, replacement, content)
                if count != 1:
                    raise ValueError(f'Wrapper edit matched {count} times: {pattern}')
        dst.write_text(content)
        rows.append(dict(source=str(src), source_sha256=sha(src), snapshot=str(dst), sha256=sha(dst), modified=src==top[0]))
        output.append(str(dst))
    result = dest / 'sources.txt'
    result.write_text('\n'.join(output)+'\n')
    (dest / 'ablation.json').write_text(json.dumps(dict(
        top=TOP, base_top='VX_gemm_unit_top', restrictions=dict(ctrl_quant_dir=0, weight_address_bit1=0),
        preserved='All weight address bits other than bit 1; all arithmetic and ACC RTL',
        substitutions=[dict(pattern=p,replacement=r) for p,r in edits], sources=rows),indent=2)+'\n')
    return result

if __name__ == '__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('sources',type=Path)
    ap.add_argument('destination',type=Path)
    a=ap.parse_args()
    print(derive_woq(a.sources,a.destination))
