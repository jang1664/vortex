#!/usr/bin/env python3
"""Static XML elaboration and complete sequential-declaration inventory.
This does not run Verilator rtlsim or synthesize/map the implementation.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BUILD = ROOT / "build_p0_boundary_storage_rev3"

def const(node):
    value = node.get("name")
    m = re.fullmatch(r"(\d+)'s?([hbd])([0-9a-fA-F]+)", value)
    assert m, value
    return int(m[3], dict(h=16,b=2,d=10)[m[2]])

def inventory(xml, mxu):
    root = ET.parse(xml).getroot()
    net = root.find("netlist")
    types = {x.get("id"): x for x in net.find("typetable")}
    files = {x.get("id"): x.get("filename") for x in root.find("files")}
    def bits(dtype):
        t = types[dtype]
        if t.tag == "basicdtype":
            return abs(int(t.get("left", "0"))-int(t.get("right", "0")))+1
        if t.tag in ("packarraydtype", "unpackarraydtype"):
            rr = t.find("range")
            return (abs(const(rr[0])-const(rr[1]))+1)*bits(t.get("sub_dtype_id"))
        if t.tag in ("enumdtype", "refdtype"):
            return bits(t.get("sub_dtype_id"))
        if t.tag == "structdtype":
            return sum(bits(x.get("sub_dtype_id")) for x in t)
        raise AssertionError(ET.tostring(t))
    modules = {m.get("name"): m for m in net.findall("module")}
    definitions = {}
    for module_name, module in modules.items():
        written = set()
        interface_written = {}
        for assignment in module.findall(".//assigndly"):
            lhs = assignment[-1]
            while lhs.tag in ("arraysel", "sel"):
                lhs = lhs[0]
            if lhs.tag == "varxref":
                key = lhs.get("dotted") + "." + lhs.get("name")
                interface_written[key] = lhs
                continue
            assert lhs.tag == "varref", (module_name, ET.tostring(lhs))
            written.add(lhs.get("name"))
        # These are procedural loop indices or same-edge FSM arithmetic temporaries,
        # not retained payload/control state. Reject any newly introduced name.
        allowed_blocking = {
            "VX_gemm_fsm_naive_meta": {"resource", "bank"},
            "VX_naive_qparam_dma": {"command", "slot"},
            "VX_gemm_node_naive": {"s"}, "VX_gemm_psum_read_ooo_join": {"slot"},
            "VX_gemm_compute_core": {"i"}, "VX_lmem_dma_misal": {"d"},
            "VX_lmem_weight_gather_dma": {"lane", "slot"}, "VX_gemm_sync_naive": {"k"},
            "VX_gemm_fsm_naive": {"kt_dim_n", "kt_rem", "mt_dim_n", "mt_rem", "nt_dim_n", "nt_rem"},
            "VX_gemm_stream_dma_queue": {"cmd", "slot"}, "VX_dma_unit_misal": {"d", "s"}}
        for always in module.findall(".//always"):
            if any(x.get("edgeType") not in ("COMBO", None) for x in always.findall("sentree/senitem")):
                for assignment in always.findall(".//assign"):
                    lhs=assignment[-1]
                    while lhs.tag in ("arraysel", "sel"): lhs=lhs[0]
                    assert lhs.get("name") in allowed_blocking.get(module.get("origName"), set()), (module_name, ET.tostring(lhs))
        variables = {}
        def visit(node, scope=""):
            for child in node:
                child_scope = scope
                if child.tag == "begin" and child.get("name"):
                    child_scope = scope + child.get("name") + "."
                if child.tag == "var" and child.get("name") in written:
                    key = child.get("name")
                    assert key not in variables, (module_name, key)
                    variables[key] = (child, scope)
                visit(child, child_scope)
        visit(module)
        definitions[module_name] = [(name, variables[name][1], bits(variables[name][0].get("dtype_id")),
                                     variables[name][0].get("loc")) for name in sorted(written)]
        definitions[module_name] += [(k, "", bits(v.get("dtype_id")), v.get("loc")) for k,v in interface_written.items()]
    records = []
    opaque = []
    for cell in root.findall(".//cell"):
        module_name = cell.get("submodname")
        if module_name not in definitions: continue
        path = cell.get("hier").replace("__BRA__", "[").replace("__KET__", "]")
        original = modules[module_name].get("origName")
        if original.startswith("xil_"): opaque.append(dict(path=path, module=original))
        for name, scope, width, loc in definitions[module_name]:
            file_id, line, *_ = loc.split(",")
            records.append(dict(path=path+"."+scope+name, module=original,
                                bits=width, source=files[file_id], line=int(line)))
    return dict(mxu=mxu, records=records, opaque_vendor_instances=opaque,
                xml=str(xml), xml_sha256=hashlib.sha256(xml.read_bytes()).hexdigest(),
                source_hashes={v:hashlib.sha256(Path(v).read_bytes()).hexdigest()
                    for v in files.values() if Path(v).is_file()},
                scope="Sequential declarations, not synthesized resources; vendor FP IP opaque")

if __name__ == "__main__":
    original = ROOT / "hw/rtl/core/gemm/VX_gemm_node_naive.sv"
    expected = original.read_text().replace("$bits(psum_wr_lmem_bus_if[i].req_data.tag)", "PSUM_ARB_TAG_WIDTH")
    assert expected == (TASK / "p4-boundary-storage-node.sv").read_text()
    for mxu in (16, 32):
        result = inventory(BUILD / f"candidate_boundary{mxu}.xml", mxu)
        result["original_node_sha256"] = hashlib.sha256(original.read_bytes()).hexdigest()
        (TASK / f"p4-boundary-storage-elaborated{mxu}.json").write_text(json.dumps(result, indent=2) + "\n")
        print(mxu, len(result["records"]), "objects; opaque", len(result["opaque_vendor_instances"]))
