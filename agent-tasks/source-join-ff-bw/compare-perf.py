#!/usr/bin/env python3
"""Compare retained perf class 3 output, without substituting another metric."""
import json, re
from pathlib import Path
ROOT = Path(__file__).resolve().parent
rows = []
for backend in ("naive", "improve"):
    for m in (1, 4, 256):
        runs = {}
        for phase in ("before", "after"):
            log = ROOT / phase / backend / f"m{m}.log"
            if not log.exists():
                continue
            data = log.read_text()
            matches = dict(re.findall(r"\b(compute_cycles|stall_cycles|total_cycles|busy_cycles|jobs)=([0-9]+)", data))
            core = re.findall(r"PERF: instrs=[0-9]+, cycles=([0-9]+)", data)
            exitfile = log.with_suffix(".exitcode")
            if not core or not exitfile.exists():
                continue
            runs[phase] = {**{k:int(v) for k,v in matches.items()}, "core_cycles":int(core[-1]),
                           "numerical_pass": "\nPASSED\n" in data and "Verified job 1/1" in data and exitfile.read_text().strip()=="0",
                           "log":str(log.relative_to(ROOT))}
        if len(runs) != 2:
            continue
        row = {"backend":backend, "M":m, **runs}
        row["delta"] = {k:runs["after"][k]-runs["before"][k] for k in ("compute_cycles","stall_cycles","total_cycles","core_cycles")}
        base = runs["before"]["compute_cycles"]
        row["compute_change_percent"] = 100*row["delta"]["compute_cycles"]/base if base else None
        assert all(r["numerical_pass"] for r in runs.values()), row
        if backend == "improve":
            assert all(v==0 for v in row["delta"].values()), row
        rows.append(row)
output = {"rows":rows,"complete":len(rows)==6,
          "metric_caveat":"Unmodified VX_gemm_compute_core leaves compute_cycles/stall_cycles unassigned (zero). A zero-to-zero comparison cannot establish unchanged performance; percentage is undefined."}
(ROOT/"performance.json").write_text(json.dumps(output,indent=2)+"\n")
print(json.dumps(output,indent=2))
