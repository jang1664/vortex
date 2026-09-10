#!/usr/bin/env python3
"""Read-only 30-minute snapshots for the URAM/BRAM spread runs; no DCP loads."""

from datetime import datetime
import importlib.util
import json
from pathlib import Path
import shutil

TASK_DIR = Path(__file__).resolve().parent
ROOT = TASK_DIR.parents[2]
module_spec = importlib.util.spec_from_file_location(
    "pnr_status", TASK_DIR.parent / "timing-cuts-pnr/status.py")
module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(module)


def snapshot():
    runs = [module.snapshot(
        ROOT, f"th32_tcol32_m32_bigmem_hbm4_tmem8_{memory}_spread_v1",
        f"TH32/HBM4/TMEM8/{memory.upper()}") for memory in ("uram", "bram")]
    return dict(checked=datetime.now().astimezone().isoformat(timespec="seconds"),
                all_terminal=all(run["terminal"] for run in runs),
                disk_free_gib=round(shutil.disk_usage(ROOT).free / 2**30, 1), runs=runs)


if __name__ == "__main__":
    result = snapshot()
    for run in result["runs"]:
        run["last_log_lines"] = [line[:400] for line in run.get("last_log_lines", [])]
    evidence = ROOT / "build_timing_cuts_pnr_artifacts/tmem_spread_v1_monitor"
    evidence.mkdir(exist_ok=True, parents=True)
    with (evidence / "history.jsonl").open("a") as stream:
        stream.write(json.dumps(result) + "\n")
    (evidence / "latest.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
