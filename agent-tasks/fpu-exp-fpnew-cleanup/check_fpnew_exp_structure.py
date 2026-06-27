#!/usr/bin/env python3
"""Structural check for the fpnew exp cleanup."""

from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parents[2]
RTL = REPO / "hw" / "rtl" / "fpu" / "VX_fpu_exp_fpnew.sv"
SYN = REPO / "hw" / "syn" / "synopsys" / "run_syn_vortex_axi.py"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


text = RTL.read_text()
match = re.search(
    r"module\s+VX_fpu_exp_fpnew\b(?P<body>.*?)\nendmodule",
    text,
    flags=re.S,
)
if not match:
    fail("VX_fpu_exp_fpnew module body not found")

body = match.group("body")
if "fpnew_top" in body:
    fail("VX_fpu_exp_fpnew main module still instantiates fpnew_top directly")

for helper in ("VX_fpu_exp_fpnew_fmul", "VX_fpu_exp_fpnew_fadd"):
    if not re.search(rf"module\s+{helper}\b", text):
        fail(f"{helper} helper module is missing")

for instance in ("fmul_t", "fadd_f"):
    if instance not in body:
        fail(f"expected {instance} arithmetic stage in VX_fpu_exp_fpnew")

syn_text = SYN.read_text()
if '"VX_ENABLE_HW_EXPF"' not in syn_text:
    fail("Synopsys define list does not enable VX_ENABLE_HW_EXPF")

print("PASS: fpnew exp structure matches cleanup intent")
