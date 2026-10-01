#!/usr/bin/env python3
"""Accept only the explicit fractional-bank range assertion, preserving its log."""
import pathlib
import subprocess
result = subprocess.run(["./simv", "+OUT_OF_RANGE", "-l", "logs/range.log"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
log = pathlib.Path("logs/range.log").read_text()
if "LMEM access out of range" not in log or "Fatal:" not in log:
    print(result.stdout[-6000:])
    raise SystemExit("Expected LMEM range assertion was not observed")
print("TEST PASSED: fractional out-of-range access rejected")
