#!/usr/bin/env python3
"""Validate the static geometry check diagnoses an incomplete bank row."""
import pathlib
import subprocess
result = subprocess.run(["./simv", "-l", "logs/rejected_geometry.log"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
text = pathlib.Path("logs/rejected_geometry.log").read_text()
if "invalid LMEM geometry:" not in text or "Error:" not in text:
    print(result.stdout[-6000:])
    raise SystemExit("Expected incomplete-bank-row diagnostic missing")
# VCS initial $error returns zero here; require the explicit rejection diagnostic.
summary = "TEST PASSED: incomplete LMEM bank row detected by static geometry check\n"
pathlib.Path("logs/sim.log").write_text(summary)
print(summary, end="")
