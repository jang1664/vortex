#!/usr/bin/env python3
"""Structural checks for one-lane job descriptor MMIO mode."""

from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parents[2]
RTL = REPO / "hw" / "rtl"

JOB_DESC = RTL / "core" / "VX_job_desc_mmio_regs.sv"
JOB_FRONTEND = RTL / "core" / "VX_job_frontend.sv"
DMA_NODE = RTL / "core" / "VX_dma_node.sv"
GEMM_NODE = RTL / "core" / "gemm" / "VX_gemm_node.sv"


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


job_desc = module_body(read(JOB_DESC), "VX_job_desc_mmio_regs")
job_frontend = module_body(read(JOB_FRONTEND), "VX_job_frontend")
dma_node = module_body(read(DMA_NODE), "VX_dma_node")
gemm_node = module_body(read(GEMM_NODE), "VX_gemm_node")

for needle in (
    "parameter bit ONE_LANE",
    "localparam int LANEID_W",
    "logic req_valid_q",
    "if (ONE_LANE) begin",
    "req_mask_valid_q",
    "req_addr_vec_q",
    "`VX_RUNTIME_ASSERT",
    "$onehot0(mmio_if.req_data.mask)",
):
    if needle not in job_desc:
        fail(f"VX_job_desc_mmio_regs missing {needle}")

for needle in (
    "parameter bit ONE_LANE_MMIO",
    ".ONE_LANE          (ONE_LANE_MMIO)",
):
    if needle not in job_frontend:
        fail(f"VX_job_frontend missing {needle}")

for needle in (
    "JOB_MMIO_DMA_DESC_ONE_LANE",
    "localparam bit JOB_DESC_ONE_LANE = 1'b1;",
    ".ONE_LANE_MMIO(JOB_DESC_ONE_LANE)",
):
    if needle not in dma_node:
        fail(f"VX_dma_node missing {needle}")

gemm_frontend = re.search(
    r"VX_job_frontend\s*#\s*\((?P<params>.*?)\)\s+\w+\s*\(",
    gemm_node,
    re.S,
)
if not gemm_frontend:
    fail("VX_gemm_node job frontend instantiation not found")

if ".ONE_LANE_MMIO(1'b1)" not in gemm_frontend.group("params"):
    fail("VX_gemm_node job frontend is not bound to one-lane MMIO")

if "VX_gemm_tmem_dma_ctrl" not in gemm_node:
    fail("VX_gemm_node is not using active VX_gemm_tmem_dma_ctrl path")

if re.search(r"\bVX_gemm_dma_ctrl\s*#", gemm_node):
    fail("VX_gemm_node should not instantiate legacy VX_gemm_dma_ctrl")

print("PASS: job descriptor one-lane structure matches expected active hierarchy")
