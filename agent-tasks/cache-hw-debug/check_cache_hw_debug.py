#!/usr/bin/env python3
"""Structural checks for cache HW debug instrumentation."""

from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parents[2]
RTL = REPO / "hw" / "rtl"
XRT = RTL / "afu" / "xrt"
RUNTIME = REPO / "runtime" / "xrt"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def read(path: Path) -> str:
    return path.read_text()


def module_body(text: str, name: str) -> str:
    match = re.search(rf"module\s+{name}\b(?P<body>.*?)\nendmodule", text, re.S)
    if not match:
        fail(f"{name} module body not found")
    return match.group("body")


gpu_pkg = read(RTL / "VX_gpu_pkg.sv")
cache_wrap = module_body(read(RTL / "cache" / "VX_cache_wrap.sv"), "VX_cache_wrap")
cache_cluster = module_body(read(RTL / "cache" / "VX_cache_cluster.sv"), "VX_cache_cluster")
socket = read(RTL / "VX_socket.sv")
cluster = read(RTL / "VX_cluster.sv")
vortex = read(RTL / "Vortex.sv")
vortex_axi = read(RTL / "Vortex_axi.sv")
afu_wrap = read(XRT / "VX_afu_wrap.sv")
hw_debug = read(XRT / "VX_hw_debug.sv")
runtime_h = read(RUNTIME / "vx_hw_debug.h")
runtime_c = read(RUNTIME / "vx_hw_debug.c")


for needle in (
    "HW_DEBUG_CACHE_MAX_PORTS",
    "HW_DEBUG_CACHE_NUM_SOURCES",
    "HW_DBG_CACHE_KIND_L1I",
    "HW_DBG_CACHE_KIND_L1D",
    "HW_DBG_CACHE_KIND_L2",
    "HW_DBG_CACHE_KIND_L3",
    "typedef struct packed",
    "cache_bus_port_debug_t",
    "cache_debug_t",
):
    if needle not in gpu_pkg:
        fail(f"VX_gpu_pkg.sv missing {needle}")

for needle in (
    "parameter DEBUG_CACHE_KIND",
    "parameter DEBUG_CACHE_LOCATION",
    "parameter DEBUG_CACHE_UNIT",
    "core_bus_if[i].req_valid",
    "core_bus_if[i].rsp_valid",
    "mem_bus_if[i].req_valid",
    "mem_bus_if[i].rsp_valid",
    "cache_debug.core_ports",
    "cache_debug.mem_ports",
):
    if needle not in cache_wrap:
        fail(f"VX_cache_wrap.sv missing cache debug hook for {needle}")

if not re.search(r"output\s+cache_debug_t\s+cache_debug", cache_wrap):
    fail("VX_cache_wrap.sv missing cache_debug output")

for path_name, text in (
    ("VX_cache_cluster.sv", cache_cluster),
    ("VX_socket.sv", socket),
    ("VX_cluster.sv", cluster),
    ("Vortex.sv", vortex),
    ("Vortex_axi.sv", vortex_axi),
    ("VX_afu_wrap.sv", afu_wrap),
):
    if "cache_debug_t" not in text:
        fail(f"{path_name} does not route cache_debug_t")
    if "ENABLE_HW_DEBUG_CACHE" not in text:
        fail(f"{path_name} cache debug routing is not cache-group macro guarded")

if not re.search(r"input\s+wire\s+cache_debug_t\s+cache_debug\s*\[HW_DEBUG_CACHE_NUM_SOURCES\]", hw_debug):
    fail("VX_hw_debug.sv does not accept cache_debug array")

for metric in (
    "DBG_CACHE_STATUS",
    "DBG_CACHE_SOURCE",
    "DBG_CACHE_PORT_LIVE",
    "DBG_CACHE_REQ_COUNTS",
    "DBG_CACHE_RSP_COUNTS",
    "DBG_CACHE_LAST_REQ",
    "DBG_CACHE_LAST_RSP",
    "DBG_CACHE_PORT_FLAGS",
    "DBG_CACHE_FIRST_STUCK",
    "DBG_CACHE_PROGRESS",
):
    if metric not in hw_debug:
        fail(f"VX_hw_debug.sv missing {metric}")

for metric in (
    "VX_HWDBG_CACHE_STATUS",
    "VX_HWDBG_CACHE_SOURCE",
    "VX_HWDBG_CACHE_PORT_LIVE",
    "VX_HWDBG_CACHE_REQ_COUNTS",
    "VX_HWDBG_CACHE_RSP_COUNTS",
    "VX_HWDBG_CACHE_LAST_REQ",
    "VX_HWDBG_CACHE_LAST_RSP",
    "VX_HWDBG_CACHE_PORT_FLAGS",
    "VX_HWDBG_CACHE_FIRST_STUCK",
    "VX_HWDBG_CACHE_PROGRESS",
):
    if metric not in runtime_h:
        fail(f"vx_hw_debug.h missing {metric}")

for needle in (
    "vx_hw_debug_cache_kind_name",
    "cache_sources",
    "VX_HWDBG_CACHE_PORT_LIVE",
    "VX_HWDBG_CACHE_PORT_FLAGS",
):
    if needle not in runtime_c:
        fail(f"vx_hw_debug.c missing {needle}")

print("PASS: cache HW debug structure is present")
