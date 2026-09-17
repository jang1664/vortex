#!/usr/bin/env python3
"""Retain PnR stage, errors and timing while the local tool run proceeds."""
import datetime, json, re, time
from collections import deque
from pathlib import Path
TASK=Path(__file__).resolve().parent
OUT=TASK/"pnr"
last_stage=None
start=datetime.datetime.fromisoformat((OUT/"start.txt").read_text().strip()).timestamp()
last_hour=int(time.time()-start)//3600
while True:
    root=Path((OUT/"output-dir.txt").read_text().strip())
    main=(OUT/"run.log").read_text(errors="replace")
    files=[OUT/"run.log"]
    files.extend(root.glob("**/runme.log"))
    files.extend(root.glob("**/vivado.log"))
    impl=root/"_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log"
    latest=impl if impl.exists() else max((f for f in files if f.exists()),key=lambda f:f.stat().st_mtime)
    with latest.open(errors="replace") as f:
        tail=list(deque(f,maxlen=100))
    milestones=[x.strip() for x in tail if re.search(r"(Phase [0-9]|Starting |Finished |Starting RTL|synth_design|place_design|route_design|phys_opt_design|write_bitstream|Step .*Started|Step .*Completed)",x)]
    stage=milestones[-1] if milestones else (last_stage or "Implementation running")
    timing=[x.strip() for x in main.splitlines() if re.search(r"WNS=|WNS |TNS |Estimated Timing|frequency.*MHz|Frequency.*MHz",x)]
    errors=[x.strip() for x in main.splitlines() if re.search(r"^ERROR:|^FATAL:|^make.*Error",x)]
    elapsed=int(time.time()-start)
    state=dict(timestamp=datetime.datetime.now().isoformat(timespec="seconds"),elapsed_seconds=elapsed,
               stage=stage,latest_log=str(latest),timing=timing[-4:],errors=errors[-5:],
               completed=(OUT/"exitcode").exists())
    if state["completed"]:state["exitcode"]=(OUT/"exitcode").read_text().strip()
    (OUT/"progress.json").write_text(json.dumps(state,indent=2)+"\n")
    hour=elapsed//3600
    if stage!=last_stage or hour>last_hour or state["completed"]:
        state["hourly_report_due"]=hour>last_hour
        print(json.dumps(state),flush=True)
        with (OUT/"progress.jsonl").open("a") as f:f.write(json.dumps(state)+"\n")
        last_stage=stage
        last_hour=hour
    if state["completed"]:break
    time.sleep(30)
