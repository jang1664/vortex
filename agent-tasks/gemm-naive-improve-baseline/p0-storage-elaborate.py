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
BUILD = ROOT / "build_p0_storage_rev3"

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
        for assignment in module.findall(".//assigndly"):
            lhs = assignment[-1]
            while lhs.tag in ("arraysel", "sel"):
                lhs = lhs[0]
            assert lhs.tag == "varref", (module_name, ET.tostring(lhs))
            written.add(lhs.get("name"))
        for always in module.findall(".//always"):
            if any(item.get("edgeType") not in ("COMBO", None) for item in always.findall("sentree/senitem")):
                for assignment in always.findall(".//assign"):
                    lhs = assignment[-1]
                    assert lhs.tag == "varref" and lhs.get("name") in ("d", "s"), (
                        "Unclassified blocking sequential assignment", module_name, ET.tostring(lhs))
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
    records = []
    for cell in root.findall(".//cell"):
        module_name = cell.get("submodname")
        if module_name not in definitions:
            continue
        path = cell.get("hier").replace("__BRA__", "[").replace("__KET__", "]")
        for name, scope, width, loc in definitions[module_name]:
            channel = 0 if ".g_channel[0]." in path else 1
            payload = unused_payload = 0
            component = "descriptor_and_executor_control"
            if "response_payload_ram" in path and name in ("ram", "rdata_r"):
                payload = width
                component = "response_ram" if name == "ram" else "response_ram_output"
            elif modules[module_name].get("origName") == "VX_dma_lane_assembler" and name in ("bank_data_r", "out_data_r"):
                payload = width
                component = "realigner_bank" if name == "bank_data_r" else "realigner_output"
            elif ".lmem_wr_buf." in path and name == "pipe":
                payload = mxu * 16
                component = "active_destination_buffer"
            elif ".dcache_wr_buf." in path and name == "pipe":
                unused_payload = mxu * 16
                component = "inactive_reverse_destination_buffer"
            elif ".rsp_skid." in path:
                component = "lane_response_join"
                if name == "ram":
                    payload = 8 * 64
                    component = "lane_response_ram"
                elif name == "data_out_r":
                    payload = 64
                    component = "lane_response_output"
            elif ".req_skid." in path:
                component = "lane_read_request_skid"
                if name in ("buffer_r", "data_out_r"):
                    unused_payload = 64
            elif ".dcache_req_buf." in path:
                component = "active_source_request_queue"
            elif ".lmem_req_buf." in path:
                component = "inactive_reverse_source_request_queue"
            assert width >= payload + unused_payload, (path, name, width, payload, unused_payload)
            file_id, line, *_ = loc.split(",")
            records.append(dict(channel="input" if channel == 0 else "combined_quant", path=path+"."+scope+name,
                                module=modules[module_name].get("origName"), bits=width,
                                operand_payload_bits=payload, inactive_or_zero_data_bits=unused_payload,
                                metadata_bits=width-payload-unused_payload, component=component,
                                source=files[file_id], line=int(line)))
    summaries = {}
    for channel in ("input", "combined_quant"):
        selected = [x for x in records if x["channel"] == channel]
        counts = {key: sum(x[key] for x in selected) for key in
                  ("bits", "operand_payload_bits", "inactive_or_zero_data_bits", "metadata_bits")}
        assert counts["operand_payload_bits"] == mxu // 16 * 928 * 8, counts
        counts["sequential_objects"] = len(selected)
        components = {}
        for component in sorted({x["component"] for x in selected}):
            components[component] = {key: sum(x[key] for x in selected if x["component"] == component)
                                    for key in ("bits", "operand_payload_bits", "inactive_or_zero_data_bits", "metadata_bits")}
        counts["components"] = components
        summaries[channel] = counts
    assert summaries["input"] == summaries["combined_quant"]
    assert not any("g_unequal" in c.get("hier", "") or "rsp_context_queue" in c.get("hier", "")
                   for c in root.findall(".//cell"))
    return dict(mxu=mxu, summaries=summaries, records=records,
                xml=str(xml), xml_sha256=hashlib.sha256(xml.read_bytes()).hexdigest(),
                scope="Elaborated sequential declarations including inactive/constant control; not post-synthesis physical resources")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reuse", action="store_true")
    parser.add_argument("--perf", action="store_true")
    args = parser.parse_args()
    assert (BUILD / "config.mk").exists(), "Configure dedicated build first"
    config = subprocess.check_output(["bash", "-c", "source configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh; printf '%s' \"$CONFIGS\""], cwd=ROOT, text=True)
    config_args = shlex.split(config)
    for mxu in (16,32):
        selected = [x for x in config_args if not any(x.startswith("-D"+key+"=") for key in
                    ("MXU_ROW","MXU_COL","MXU_COL_TILE","LMEM_NUM_PORTS"))]
        selected += [f"-DMXU_ROW={mxu}",f"-DMXU_COL={mxu}",f"-DMXU_COL_TILE={mxu}",f"-DLMEM_NUM_PORTS={mxu}"]
        suffix = "-perf" if args.perf else ""
        xml = BUILD / f"storage{mxu}{suffix}.xml"
        command = ["verilator", "--xml-only", "--xml-output", str(xml), "--top-module", "p0_storage_probe",
                   "-Wno-fatal", "-DSYNTHESIS", "-DNDEBUG", "-DXLEN_64", *selected,
                   "+incdir+"+str(ROOT/"hw/rtl")]
        if args.perf:
            command.append("-DPERF_ENABLE")
        for directory in ("libs","core","core/gemm","mem"):
            command += ["-y",str(ROOT/"hw/rtl"/directory)]
        command += [str(ROOT/"hw/rtl/VX_gpu_pkg.sv"),str(TASK/"p0-storage-probe.sv")]
        if not args.reuse:
            with (BUILD/f"storage{mxu}{suffix}.compile.log").open("w") as log:
                subprocess.run(command,cwd=BUILD,stdout=log,stderr=subprocess.STDOUT,check=True)
        result = inventory(xml,mxu)
        result["perf_enabled"] = args.perf
        result["command"] = command
        result["tool_version"] = subprocess.check_output(["verilator","--version"],text=True).strip()
        result["script_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        result["probe_sha256"] = hashlib.sha256((TASK/"p0-storage-probe.sv").read_bytes()).hexdigest()
        source_files = {x.get("filename") for x in ET.parse(xml).getroot().find("files")
                        if str(ROOT / "hw/rtl") in x.get("filename", "")}
        result["source_hashes"] = {name:hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in sorted(source_files)}
        provenance_path = BUILD / f"storage{mxu}{suffix}.provenance.json"
        provenance = {"source_hashes": result["source_hashes"], "probe_sha256": result["probe_sha256"],
                      "command": command, "xml_sha256": result["xml_sha256"]}
        if args.reuse:
            assert json.loads(provenance_path.read_text()) == provenance, "Stale elaboration: rerun without --reuse"
        else:
            provenance_path.write_text(json.dumps(provenance, indent=2)+"\n")
        (TASK/f"p0-storage-elaborated-mxu{mxu}{suffix}.json").write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps({"mxu":mxu,"input":{k:v for k,v in result["summaries"]["input"].items() if k!='components'}},indent=2))
if __name__ == "__main__":
    main()
