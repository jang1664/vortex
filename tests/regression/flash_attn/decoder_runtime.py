"""Exact ELF-backed global/TLS storage used by the C4 decoder runtime.

This describes observed runtime addresses; it does not fix the uploader's
separate omission of per-hart TLS from its static-image reservation.
"""
import hashlib
from pathlib import Path
import re
import shutil
import subprocess


def require(condition, message):
    if not condition:
        raise ValueError(message)


def contract(symbols, cores, warps, threads, image_start, image_bytes):
    def value(name):
        require(name in symbols, f"ELF missing runtime symbol {name}")
        return symbols[name]["value"]
    start, end = value("_edata"), value("_end")
    stride = value("__tbss_size")
    require(value("__tdata_size") == 0 and value("__tbss_offset") == 0,
            "initialized or offset TLS needs a separate source-backed contract")
    require(stride == 40 and (cores, warps, threads) == (1,4,16), "unsupported C4 TLS geometry")
    require(image_start < start < end == image_start+image_bytes,
            "ELF static-image end disagrees with the kernel reservation")
    require(value("__bss_start") == start and end-start <= 64, "unexpected BSS initialization span")
    globals_expected = {"__warps_per_group":4, "blockDim":12, "gridDim":12}
    globals_actual = {name:s["size"] for name,s in symbols.items()
                      if s["type"] == "OBJECT" and start <= s["value"] < end and s["size"]}
    require(globals_actual == globals_expected, "unknown BSS objects; refuse intermediate/global spill allowance")
    for name, size in globals_expected.items():
        require(value(name)+size <= end, "global object exceeds initialized BSS")
    tls_expected = {"__local_group_id":(0,4), "threadIdx":(8,12), "blockIdx":(24,12)}
    tls_actual = {name:(s["value"],s["size"]) for name,s in symbols.items() if s["type"] == "TLS"}
    require(tls_actual == tls_expected, "unexpected TLS objects; refuse attention-state allowance")
    tls_end = end+cores*warps*threads*stride
    require(tls_end < (1<<34), "TLS exceeds C4 address space")
    return dict(bss=(start,end-start), tls=(end,tls_end-end), tls_stride=stride,
                harts=cores*warps*threads, global_objects=globals_actual, tls_objects=tls_actual,
                static_reservation_end=end, allocator_page_end=(end+4095)&~4095,
                tls_past_allocator_page_bytes=max(0,tls_end-((end+4095)&~4095)),
                allocation_note="TLS traffic attribution only; static uploader reservation does not include all per-hart TLS")


def from_elf(path, geometry, image_start, image_bytes):
    path = Path(path)
    tool = shutil.which("readelf")
    require(tool is not None, "readelf is required for exact runtime symbol evidence")
    header = path.read_bytes()[:20]
    require(header[:7] == b"\x7fELF\x02\x01\x01" and int.from_bytes(header[18:20],"little") == 243,
            "expected little-endian ELF64 RISC-V image")
    output = subprocess.check_output([tool,"-sW",str(path.resolve())],text=True)
    entries = []
    for line in output.splitlines():
        m = re.match(r"\s*\d+:\s+([0-9a-fA-F]+)\s+(\d+)\s+(\w+)\s+\w+\s+\w+\s+\S+\s+(\S+)\s*$",line)
        if not m: continue
        address,size,kind,name=m.groups()
        record=dict(value=int(address,16),size=int(size),type=kind)
        entries.append((name,record))
    required = {"_edata", "_end", "__bss_start", "__tbss_size", "__tbss_offset", "__tdata_size"}
    bounds = {name:record["value"] for name,record in entries if name in {"_edata","_end"}}
    require(set(bounds) == {"_edata","_end"}, "missing ELF static-image bounds")
    symbols = {}
    for name, record in entries:
        relevant = (name in required or record["type"] == "TLS" or
                    (record["type"] == "OBJECT" and bounds["_edata"] <= record["value"] < bounds["_end"]))
        if not relevant: continue
        if name in symbols and symbols[name] != record:
            raise ValueError(f"ambiguous ELF runtime symbol {name}")
        symbols[name]=record
    result=contract(symbols,geometry["cores"],geometry["warps"],geometry["threads"],image_start,image_bytes)
    result.update(elf=str(path.resolve()),elf_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def valid_mask(address, region):
    base,size=region
    return sum(1<<byte for byte in range(64) if base <= address+byte < base+size)


def write_region(address, strobe, runtime):
    require(0 < strobe < (1<<64), "invalid write byte strobe")
    for name in ("bss","tls"):
        mask=valid_mask(address,runtime[name])
        if mask and strobe & ~mask == 0:
            return "runtime_"+name
    return None
