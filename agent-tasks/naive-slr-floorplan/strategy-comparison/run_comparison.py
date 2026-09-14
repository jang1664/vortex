#!/usr/bin/env python3
"""Run two fresh wrapper builds; preserve exit status and hourly evidence."""
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD = ROOT / "build/hw/syn/xilinx/xrt"
PROFILE = "naive_th16_tcol16_m16_L16_bigmem_all_bram"
PLATFORM = "/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm"
POSTFIX = "compare_20260914_v1"
LOCK = threading.Lock()


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def tail(path, count=8):
    if not path.exists():
        return []
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - 32768))
        return stream.read().decode(errors="replace").splitlines()[-count:]


def evidence(state):
    physical = Path(state["physical_output"])
    impl = physical / "_x/link/vivado/vpl/prj/prj.runs/impl_1"
    result = {"checked": now(), "state": dict(state),
              "implementation_tail": tail(impl / "runme.log"),
              "wrapper_tail": tail(Path(state["record_dir"]) / "wrapper.log"),
              "reports": {}, "errors": [], "timing_summaries": [],
              "xclbin": [str(p) for p in (physical / "bin").glob("*.xclbin")]}
    log = impl / "runme.log"
    if log.exists():
        with log.open(errors="replace") as stream:
            for line in stream:
                if "ERROR:" in line:
                    result["errors"].append(line.strip()[:2000])
                if "WNS=" in line or "highly congested" in line or "Super Long Lines" in line:
                    result["timing_summaries"].append(line.strip()[:2000])
        result["errors"] = result["errors"][-30:]
    for report in impl.glob("*.rpt"):
        if any(word in report.name for word in ("timing_summary", "utilization", "congestion", "slr_util", "drc")):
            result["reports"][report.name] = {"path": str(report), "bytes": report.stat().st_size}
    return result


def snapshot(states, label):
    with LOCK:
        values = {key: evidence(value) for key, value in states.items()}
        write_json(HERE / "runs" / (label + ".json"), values)
        write_json(HERE / "runs/latest.json", values)
        lines = ["# PnR strategy comparison", "", "Updated: " + now(), "",
                 "Both runs use fresh synthesis through build/hw/syn/xilinx/xrt/run_hw.sh.",
                 "Common: 100 MHz, U55C, MXU16, LMEM1 MiB/16 banks/all BRAM, FAST_MODE=0,",
                 "no PERF/DEBUG, congestion early termination disabled, standard Vitis optimize=3.", "",
                 "| Strategy | State | Exit code | Elapsed seconds | Xclbin |",
                 "| --- | --- | --- | --- | --- |"]
        for key, value in values.items():
            state = value["state"]
            elapsed = state.get("elapsed_seconds", round(time.time() - state["started_epoch"]))
            lines.append(f"| {key} | {state['state']} | {state.get('returncode', '')} | {elapsed} | {bool(value['xclbin'])} |")
        for key, value in values.items():
            lines += ["", "## " + key, "", "Output: `" + value["state"]["physical_output"] + "`", "",
                      "Latest implementation log:", "", "```", *value["implementation_tail"], "```", "",
                      "Timing/congestion log summaries (placed estimates are not routed timing):", "",
                      "```", *value["timing_summaries"][-8:], "```"]
        lines += ["", "Final route status, timing/DRC and source provenance require review before claiming success.", ""]
        (HERE / "results.md").write_text("\n".join(lines))


def run(state):
    record = Path(state["record_dir"])
    env = os.environ.copy()
    for key in ("PERF", "DEBUG", "PROFILE", "VPP_FLAGS", "MAKEFLAGS", "MFLAGS", "CONFIGS",
                "GEMM_SLR_FLOORPLAN", "PLACE_DESIGN_DIRECTIVE", "ROUTE_DESIGN_DIRECTIVE",
                "IMPL_ULTRATHREADS", "FAST_MODE", "CONGESTION_FAIL_FAST"):
        env.pop(key, None)
    env["PLATFORM"] = PLATFORM
    with (record / "wrapper.log").open("w") as log:
        process = subprocess.Popen(state["command"], cwd=ROOT, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        with LOCK:
            state.update(state="running", wrapper_pid=process.pid)
            write_json(record / "state.json", state)
        code = process.wait()
    with LOCK:
        state.update(state="finished", returncode=code, finished=now(),
                     elapsed_seconds=round(time.time() - state["started_epoch"]))
        write_json(record / "state.json", state)
    return code


def main():
    approved = json.loads((HERE.parent / "runs/attribute-preserve-v1/rtl-provenance.json").read_text())["rtl_sha256"]
    changed = [name for name, digest in approved.items()
               if hashlib.sha256((ROOT / "hw/rtl" / name).read_bytes()).hexdigest() != digest]
    if changed:
        raise RuntimeError("RTL differs from verified candidate: " + repr(changed))
    hashes = {}
    for folder in (ROOT / "hw/rtl", ROOT / "hw/syn/xilinx/xrt"):
        for path in folder.rglob("*"):
            if path.is_file() and (path.suffix in (".sv", ".svh", ".v", ".vh", ".tcl", ".py", ".in", ".mk") or path.name == "Makefile"):
                hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    states = {}
    for strategy, profile, slr in (("slr", PROFILE, "1"), ("base", PROFILE + "_base", "0")):
        config = ROOT / "configs" / (profile + ".sh")
        hashes[str(config.relative_to(ROOT))] = hashlib.sha256(config.read_bytes()).hexdigest()
        record = HERE / "runs" / strategy
        physical = BUILD / f"{profile}_{POSTFIX}_{Path(PLATFORM).stem}_hw"
        if record.exists() or physical.exists():
            raise RuntimeError("Refusing to overwrite existing run: " + strategy)
        record.mkdir()
        (record / config.name).write_bytes(config.read_bytes())
        states[strategy] = {"strategy": strategy, "state": "starting", "started": now(),
                           "started_epoch": time.time(), "manager_pid": os.getpid(),
                           "record_dir": str(record), "physical_output": str(physical),
                           "command": [str(BUILD / "run_hw.sh"), "--config", profile,
                                       "--postfix", POSTFIX, "--slr-floorplan", slr,
                                       "--no-early-fail", "FAST_MODE=0"]}
        write_json(record / "state.json", states[strategy])
    write_json(HERE / "runs/source_hashes.json", hashes)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        pending = {pool.submit(run, state) for state in states.values()}
        next_check = time.monotonic() + 3600
        hourly = 0
        while pending:
            done, pending = concurrent.futures.wait(pending, timeout=max(0, next_check - time.monotonic()),
                                                   return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                future.result()
            if done:
                snapshot(states, "completion_" + str(time.time_ns()))
            if time.monotonic() >= next_check:
                hourly += 1
                snapshot(states, f"hour_{hourly:02d}")
                next_check = time.monotonic() + 3600
    write_json(HERE / "runs/source_changes.json", [name for name, digest in hashes.items()
               if not (ROOT / name).exists() or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest])
    snapshot(states, "final")


if __name__ == "__main__":
    main()
