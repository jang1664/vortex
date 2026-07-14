#!/usr/bin/env python3
"""Structural checks for HW debug group macro gating."""

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


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        fail(f"{label} missing {needle}")


def require_regex(text: str, pattern: str, label: str, message: str) -> None:
    if not re.search(pattern, text, re.S):
        fail(f"{label} {message}")


define_vh = read(RTL / "VX_define.vh")
hw_debug = read(XRT / "VX_hw_debug.sv")
afu_wrap = read(XRT / "VX_afu_wrap.sv")
opae_afu = read(RTL / "afu" / "opae" / "vortex_afu.sv")
vortex_axi = read(RTL / "Vortex_axi.sv")
vortex = read(RTL / "Vortex.sv")
cluster = read(RTL / "VX_cluster.sv")
socket = read(RTL / "VX_socket.sv")
core = read(RTL / "core" / "VX_core.sv")
issue = read(RTL / "core" / "VX_issue.sv")
issue_slice = read(RTL / "core" / "VX_issue_slice.sv")
commit = read(RTL / "core" / "VX_commit.sv")
cache_wrap = read(RTL / "cache" / "VX_cache_wrap.sv")
cache_cluster = read(RTL / "cache" / "VX_cache_cluster.sv")
gemm_node = read(RTL / "core" / "gemm" / "VX_gemm_node.sv")
gemm_unit = read(RTL / "core" / "gemm" / "VX_gemm_unit.sv")
runtime_h = read(RUNTIME / "vx_hw_debug.h")
runtime_c = read(RUNTIME / "vx_hw_debug.c")


for macro in (
    "ENABLE_HW_DEBUG_BASE",
    "ENABLE_HW_DEBUG_AFU",
    "ENABLE_HW_DEBUG_AXI",
    "ENABLE_HW_DEBUG_PC",
    "ENABLE_HW_DEBUG_CORE",
    "ENABLE_HW_DEBUG_CACHE",
    "ENABLE_HW_DEBUG_GEMM",
):
    require(define_vh, macro, "VX_define.vh")

require_regex(
    define_vh,
    r"`ifdef\s+ENABLE_HW_DEBUG_MODULE.*?`define\s+ENABLE_HW_DEBUG_BASE.*?`define\s+ENABLE_HW_DEBUG_AFU",
    "VX_define.vh",
    "does not default ENABLE_HW_DEBUG_MODULE to BASE+AFU",
)
for opt_in in (
    "ENABLE_HW_DEBUG_AXI",
    "ENABLE_HW_DEBUG_PC",
    "ENABLE_HW_DEBUG_CORE",
    "ENABLE_HW_DEBUG_CACHE",
    "ENABLE_HW_DEBUG_GEMM",
):
    if re.search(rf"`ifdef\s+ENABLE_HW_DEBUG_MODULE.*?`define\s+{opt_in}", define_vh, re.S):
        fail(f"VX_define.vh must not default {opt_in}; it should be opt-in")


for cap in (
    "VX_HWDBG_CAP_BASE",
    "VX_HWDBG_CAP_AFU",
    "VX_HWDBG_CAP_AXI",
    "VX_HWDBG_CAP_PC",
    "VX_HWDBG_CAP_CORE",
    "VX_HWDBG_CAP_CACHE",
    "VX_HWDBG_CAP_GEMM",
):
    require(runtime_h, cap, "vx_hw_debug.h")
require(runtime_c, "vx_hw_debug_status_has_cap", "vx_hw_debug.c")
require(hw_debug, "HW_DEBUG_CAPS", "VX_hw_debug.sv")


for label, text, macros in (
    ("VX_afu_wrap.sv", afu_wrap, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("vortex_afu.sv", opae_afu, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("Vortex_axi.sv", vortex_axi, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("Vortex.sv", vortex, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("VX_cluster.sv", cluster, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("VX_socket.sv", socket, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_CACHE", "ENABLE_HW_DEBUG_GEMM")),
    ("VX_core.sv", core, ("ENABLE_HW_DEBUG_PC", "ENABLE_HW_DEBUG_CORE", "ENABLE_HW_DEBUG_GEMM")),
    ("VX_issue.sv", issue, ("ENABLE_HW_DEBUG_CORE",)),
    ("VX_issue_slice.sv", issue_slice, ("ENABLE_HW_DEBUG_CORE",)),
    ("VX_commit.sv", commit, ("ENABLE_HW_DEBUG_PC",)),
    ("VX_cache_wrap.sv", cache_wrap, ("ENABLE_HW_DEBUG_CACHE",)),
    ("VX_cache_cluster.sv", cache_cluster, ("ENABLE_HW_DEBUG_CACHE",)),
    ("VX_gemm_node.sv", gemm_node, ("ENABLE_HW_DEBUG_GEMM",)),
    ("VX_gemm_unit.sv", gemm_unit, ("ENABLE_HW_DEBUG_GEMM",)),
):
    for macro in macros:
        require(text, macro, label)

require_regex(
    hw_debug,
    r"`ifdef\s+ENABLE_HW_DEBUG_AXI.*?DBG_AXI_AW_FIRE",
    "VX_hw_debug.sv",
    "does not guard AXI readback with ENABLE_HW_DEBUG_AXI",
)
require_regex(
    hw_debug,
    r"`ifdef\s+ENABLE_HW_DEBUG_CORE.*?DBG_CORE_STATUS",
    "VX_hw_debug.sv",
    "does not guard core readback with ENABLE_HW_DEBUG_CORE",
)
require_regex(
    hw_debug,
    r"`ifdef\s+ENABLE_HW_DEBUG_CACHE.*?DBG_CACHE_STATUS",
    "VX_hw_debug.sv",
    "does not guard cache readback with ENABLE_HW_DEBUG_CACHE",
)
require_regex(
    hw_debug,
    r"`ifdef\s+ENABLE_HW_DEBUG_GEMM.*?DBG_GEMM_STATUS",
    "VX_hw_debug.sv",
    "does not guard GEMM readback with ENABLE_HW_DEBUG_GEMM",
)

print("PASS: HW debug group macro gating is structurally present")
