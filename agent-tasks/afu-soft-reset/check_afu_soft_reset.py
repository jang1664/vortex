#!/usr/bin/env python3
"""Structural checks for AFU soft-reset cleanup."""

from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parents[2]
XRT = REPO / "hw" / "rtl" / "afu" / "xrt"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


afu_ctrl = (XRT / "VX_afu_ctrl.sv").read_text()
afu_wrap = (XRT / "VX_afu_wrap.sv").read_text()

if "ap_reset_req" not in afu_ctrl:
    fail("VX_afu_ctrl.sv missing decoded AP_RESET write request")

for needle in (
    "if (reset || ap_reset_req) begin",
    "ap_start_r <= 0;",
    "auto_restart_r <= 0;",
    "isr_r <= '0;",
):
    if needle not in afu_ctrl:
        fail(f"VX_afu_ctrl.sv missing soft-reset cleanup for {needle}")

if not re.search(
    r"VX_axi_write_ack\s+axi_write_ack\s*\([\s\S]*?\.reset\s*\(\s*reset\s*\|\|\s*ap_reset\s*\)",
    afu_wrap,
):
    fail("VX_afu_wrap.sv does not soft-reset AFU write-ack trackers")

if "vx_pending_writes <= '0;" not in afu_wrap:
    fail("existing vx_pending_writes reset was unexpectedly removed")

print("PASS: AFU soft-reset cleanup structure is present")
