#!/usr/bin/env python3
import json
from pathlib import Path
root = Path(__file__).resolve().parent
baseline = json.loads((root / "baseline/results.json").read_text())
candidate = json.loads((root / "candidate/results.json").read_text())
old = {case["name"]: case for case in baseline["cases"]}
rows = []
for new in candidate["cases"]:
    before = old[new["name"]]
    valid = all(c["exit_code"] == 0 and c["pass_marker"] for c in [before, new])
    row = {"case": new["name"], "valid": valid, "args": new["args"]}
    for label, a, b in [
        ("core", before["core_cycles"], new["core_cycles"]),
        ("attention", before["attention_cycles"].get("total"), new["attention_cycles"].get("total"))]:
        row[label] = {"baseline_cycles": a, "candidate_cycles": b,
                      "delta_cycles": b-a if valid and a is not None and b is not None else None,
                      "delta_percent": 100.0*(b-a)/a if valid and a and b is not None else None,
                      "speedup": a/b if valid and a and b else None}
    rows.append(row)
report = {"metric": "RTL simulation cycles under identical C4 config and DISABLE_FSDB", "fmax_measured": False,
          "note": "Candidate integrates SRAM copy into GEMM completion, so compare total/core cycles rather than individual submit/wait/copy phase labels.", "cases": rows}
(root / "cycle_comparison.json").write_text(json.dumps(report, indent=2) + "\n")
for row in rows:
    print(row["case"], "PASS" if row["valid"] else "INVALID", row["core"], row["attention"])
