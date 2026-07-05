#!/usr/bin/env python3
"""Structural checks for core pipeline HW debug instrumentation."""

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


gpu_pkg = read(RTL / "VX_gpu_pkg.sv")
core = read(RTL / "core" / "VX_core.sv")
socket = read(RTL / "VX_socket.sv")
cluster = read(RTL / "VX_cluster.sv")
vortex = read(RTL / "Vortex.sv")
vortex_axi = read(RTL / "Vortex_axi.sv")
afu_wrap = read(XRT / "VX_afu_wrap.sv")
hw_debug = read(XRT / "VX_hw_debug.sv")
runtime_h = read(RUNTIME / "vx_hw_debug.h")


for needle in (
    "HW_DEBUG_CORE_PIPE_CHANNELS",
    "HW_DEBUG_CORE_STALL_TIMEOUT",
    "typedef struct packed",
    "hw_debug_vr_t",
    "core_pipeline_debug_t",
):
    if needle not in gpu_pkg:
        fail(f"VX_gpu_pkg.sv missing {needle}")

probe = RTL / "libs" / "VX_hw_debug_vr_probe.sv"
if not probe.exists():
    fail("VX_hw_debug_vr_probe.sv is missing")

probe_text = read(probe)
for needle in (
    "module VX_hw_debug_vr_probe",
    "payload_changed",
    "valid && !ready",
):
    if needle not in probe_text:
        fail(f"VX_hw_debug_vr_probe.sv missing {needle}")

for path_name, text in (
    ("VX_core.sv", core),
    ("VX_socket.sv", socket),
    ("VX_cluster.sv", cluster),
    ("Vortex.sv", vortex),
    ("Vortex_axi.sv", vortex_axi),
    ("VX_afu_wrap.sv", afu_wrap),
):
    if "core_pipeline_debug_t" not in text:
        fail(f"{path_name} does not route core_pipeline_debug_t")
    if "ENABLE_HW_DEBUG_MODULE" not in text:
        fail(f"{path_name} debug routing is not macro guarded")

for channel in (
    "HW_DBG_CH_SCHEDULE",
    "HW_DBG_CH_ICACHE_REQ",
    "HW_DBG_CH_ICACHE_RSP",
    "HW_DBG_CH_FETCH",
    "HW_DBG_CH_DECODE",
    "HW_DBG_CH_DISPATCH_BASE",
    "HW_DBG_CH_COMMIT_BASE",
    "HW_DBG_CH_LSU_REQ_BASE",
    "HW_DBG_CH_LSU_RSP_BASE",
    "HW_DBG_CH_DCACHE_REQ_BASE",
    "HW_DBG_CH_DCACHE_RSP_BASE",
):
    if channel not in core:
        fail(f"VX_core.sv missing probe for {channel}")

for metric in (
    "DBG_CORE_STATUS",
    "DBG_CORE_CHANNEL",
    "DBG_CORE_FLAGS",
    "DBG_CORE_FIRST_STUCK",
    "DBG_CORE_PROGRESS",
):
    if metric not in hw_debug:
        fail(f"VX_hw_debug.sv missing {metric}")

for metric in (
    "VX_HWDBG_CORE_STATUS",
    "VX_HWDBG_CORE_CHANNEL",
    "VX_HWDBG_CORE_FLAGS",
    "VX_HWDBG_CORE_FIRST_STUCK",
    "VX_HWDBG_CORE_PROGRESS",
):
    if metric not in runtime_h:
        fail(f"vx_hw_debug.h missing {metric}")

if not re.search(r"input\s+wire\s+core_pipeline_debug_t\s+core_pipeline_debug\s*\[HW_DEBUG_NUM_PC_SOURCES\]", hw_debug):
    fail("VX_hw_debug.sv does not accept per-core pipeline debug array")

print("PASS: core pipeline HW debug structure is present")
