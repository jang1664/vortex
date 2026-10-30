#!/usr/bin/env python3
import json,re
from pathlib import Path
folder=Path(__file__).resolve().parent
cases=[("mmio_serialization", "mmio_serialization", ""), ("sram_early_return_retry1200", "sram_early_return", ""), ("fp32_pv_overflow", "flash_attn", "-r -f -m 1 -n 128 -s pv-overflow"), ("fp32_qk_overflow", "flash_attn", "-r -f -m 1 -n 128 -s qk-overflow")]
results=[]
for name,app,args in cases:
    rc=folder/(name+".exit")
    if not rc.exists():continue
    log=(folder/(name+".log")).read_text(errors="replace")
    results.append({"name":name,"app":app,"args":args,"exit_code":int(rc.read_text()),"pass_marker":bool(re.search(r"^PASSED$",log,re.M)),"evidence":[line for line in log.splitlines() if line.startswith(("MMIO_SERIALIZATION ","SRAM_EARLY_RETURN ","ATTENTION_CYCLES ","FP32_", "RESULT ","PERF: instrs="))],"log":str(folder/(name+".log"))})
(folder/"functionality_results.json").write_text(json.dumps({"cases":results},indent=2)+"\n")
for row in results:print(row["name"],row["exit_code"],row["pass_marker"],row["evidence"])
