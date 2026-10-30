#!/usr/bin/env python3
import hashlib
import json
import re
from pathlib import Path
folder = Path(__file__).resolve().parent
cases = {
    "fp32_multitile": "-r -f -m 4 -n 256",
    "fp16_multitile": "-r -m 4 -n 256",
    "legacy_single": "-m 4 -n 128",
    "fp32_tail": "-r -f -m 16 -n 257",
    "fp32_mask": "-r -f -m 16 -n 384 -c -p 0",
}
results = []
for name, args in cases.items():
    rc = folder / (name + ".exit")
    if not rc.exists():
        continue
    log = (folder / (name + ".log")).read_text(errors="replace")
    cycles = re.search(r"^ATTENTION_CYCLES (.+)$", log, re.M)
    fields = dict(re.findall(r"(\w+)=(\d+)", cycles.group(1))) if cycles else {}
    perf = re.findall(r"PERF: instrs=(\d+), cycles=(\d+), IPC=([0-9.]+)", log)
    results.append({
        "name": name,
        "args": args,
        "exit_code": int(rc.read_text()),
        "pass_marker": bool(re.search(r"^PASSED$", log, re.M)),
        "attention_cycles": {k: int(v) for k, v in fields.items()},
        "core_cycles": int(perf[-1][1]) if perf else None,
        "instructions": int(perf[-1][0]) if perf else None,
        "log": str(folder / (name + ".log")),
        "started": (folder / (name + ".started")).read_text().strip(),
        "finished": (folder / (name + ".finished")).read_text().strip(),
    })
summary = {"setup": json.loads((folder / "setup.json").read_text()), "cases": results}
(folder / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
for result in results:
    print(result["name"], result["exit_code"], result["pass_marker"], result["attention_cycles"])
