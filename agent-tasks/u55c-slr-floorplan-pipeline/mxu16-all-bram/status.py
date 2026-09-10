#!/usr/bin/env python3
"""Read-only snapshots of the MXU16 all-BRAM PnR run."""

from datetime import datetime
import importlib.util
import json
from pathlib import Path
import shutil

TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[2]
TAG = "th16_tcol16_m16_t8_bigmem_all_bram_spread_v1"
spec = importlib.util.spec_from_file_location(
    "pnr_status", TASK.parent / "timing-cuts-pnr/status.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

if __name__ == "__main__":
    run = module.snapshot(ROOT, TAG, "MXU16/HBM4/DMA4/TMEM8/all-BRAM")
    run["last_log_lines"] = [line[:400] for line in run.get("last_log_lines", [])]
    result = dict(checked=datetime.now().astimezone().isoformat(timespec="seconds"),
                  all_terminal=run["terminal"],
                  disk_free_gib=round(shutil.disk_usage(ROOT).free / 2**30, 1), runs=[run])
    evidence = ROOT / "build_timing_cuts_pnr_artifacts/mxu16_all_bram_spread_v1_monitor"
    evidence.mkdir(parents=True, exist_ok=True)
    with (evidence / "history.jsonl").open("a") as stream:
        stream.write(json.dumps(result) + "\n")
    (evidence / "latest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
