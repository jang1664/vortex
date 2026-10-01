#!/usr/bin/env python3
"""Derive the current GEMM_IMPROVE WoQ wrapper; preserve every dependency."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
TOP = 'VX_woq_gemm_unit_top'
PATCH = ROOT / 'hw/rtl/patch/VX_woq_gemm_unit_top.sv'
spec = importlib.util.spec_from_file_location('shared_woq_derivation', ROOT / 'agent-tasks/array-fpga-study/prepare_woq.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
shared.TOP = TOP


def check_patch():
    """Keep the reviewable raw patch and measured snapshot specialization equal."""
    raw = (ROOT / 'hw/rtl/core/gemm/VX_gemm_unit_top.sv').read_text()
    raw = raw.replace('module VX_gemm_unit_top ', 'module '+TOP+' ', 1)
    raw = raw.replace('= ctrl_quant_dir;', "= 1'b0;")
    raw = raw.replace('= w_req_addr;', "= {w_req_addr[ADDR_WIDTH-1:2], 1'b0, w_req_addr[0]};")
    def tokens(s):
        return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', s, flags=re.S))
    if tokens(raw) != tokens(PATCH.read_text()):
        raise ValueError('Reviewable WoQ patch diverged from the wrapper specialization')


def derive_woq(flist, dest):
    check_patch()
    flist = Path(flist).resolve()
    snapshot = flist.parent / 'snapshot.json'
    if snapshot.exists():
        defines = json.loads(snapshot.read_text())['defines']
        if '-DGEMM_IMPROVE' not in defines or any(d.split('=')[0] == '-DGEMM_NAIVE' for d in defines):
            raise ValueError('WoQ resource ablation requires GEMM_IMPROVE without GEMM_NAIVE')
    result = shared.derive_woq(flist, dest)
    manifest_path = result.parent / 'ablation.json'
    manifest = json.loads(manifest_path.read_text())
    manifest.update(reviewable_patch=str(PATCH), reviewable_patch_sha256=shared.sha(PATCH),
        excluded_historical_modules=['VX_woq_gemm_unit', 'VX_woq_gemm_tree', 'VX_woq_gemm_weight_regs_v1', 'VX_woq_pe_tree'],
        specialization='quant_dir=QCOL and weight address bit 1=0; native internal ACC and current GEMM_IMPROVE dependencies retained')
    manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
    return result


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('sources', type=Path)
    ap.add_argument('destination', type=Path)
    args = ap.parse_args()
    print(derive_woq(args.sources, args.destination))
