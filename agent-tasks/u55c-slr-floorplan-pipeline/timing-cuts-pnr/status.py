#!/usr/bin/env python3
"""Small read-only snapshot for the hourly PnR monitor; never opens DCPs."""

from datetime import datetime
import json
import os
from pathlib import Path


def tail(path, limit=32768):
    if not path.is_file():
        return ""
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - limit))
        return stream.read().decode(errors="replace")


def snapshot(root, tag, label):
    state_path = root / f"build_timing_cuts_pnr_artifacts/{tag}/state.json"
    if not state_path.exists():
        return dict(config=label, status="pending_launch", terminal=False)
    state = json.loads(state_path.read_text())
    output = Path(state["output"])
    terminal = state["status"] in ("complete", "failed", "configure_failed", "runner_failed")
    stage = state["status"]
    markers = []
    project_runs = output / "_x/link/vivado/vpl/prj/prj.runs"
    if not terminal:
        for run in (project_runs / "impl_1", project_runs / "synth_1"):
            for marker in run.glob(".*.begin.rst"):
                markers.append((marker.stat().st_mtime, run.name, marker.name))
        if markers:
            _, run_name, marker = max(markers)
            step = marker.removeprefix(".").removesuffix(".begin.rst")
            stage = f"{run_name}: {step}"
        elif (output / "_x/link").exists():
            stage = "Vitis link / synthesis preparation"
        elif (output / "bin/vortex_afu.xo").exists():
            stage = "kernel packaged; preparing link"
        elif (output / "vivado.log").exists():
            stage = "IP generation / kernel packaging"
    recent = tail(Path(state["log"]))
    errors = [line for line in recent.splitlines()
              if line.startswith(("ERROR:", "make: ***", "make[1]: ***"))]
    alive = True
    try:
        os.kill(state["runner_pid"], 0)
    except ProcessLookupError:
        alive = False
    return dict(config=label, status=state["status"], stage=stage,
                terminal=terminal, runner_alive=alive, started=state["started"],
                finished=state.get("finished"), returncode=state.get("returncode"),
                xclbin_exists=Path(state["xclbin"]).is_file(), xclbin=state["xclbin"],
                log=state["log"], last_errors=errors[-4:],
                last_log_lines=recent.splitlines()[-4:])


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[3]
    runs = [snapshot(root, f"th32_t{count}_slr_v3", f"TH32/t{count}") for count in (4, 8)]
    runs.append(snapshot(root, "th32_tcol32_m32_bigmem_hbm4_tmem8_slr_v3", "TH32/HBM4/TMEM8"))
    print(json.dumps(dict(checked=datetime.now().astimezone().isoformat(timespec="seconds"),
                          all_terminal=all(run["terminal"] for run in runs), runs=runs), indent=2))
