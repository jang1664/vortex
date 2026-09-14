#!/usr/bin/env python3
"""Record a user-authorized fresh run through the configured build wrapper."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--postfix", default="naive_slr_100m_v1")
parser.add_argument("--resume-postfix", help="Reuse a failed run's synthesis for a Tcl-only implementation correction")
parser.add_argument("--attribute-candidate", action="store_true", help="Use the separately verified naive weight-TX preservation candidate")
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.postfix):
    parser.error("invalid postfix")
if args.resume_postfix and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.resume_postfix):
    parser.error("invalid resume postfix")
gate = TASK / ("runs/attribute-preserve-v1/gate.json" if args.attribute_candidate else "verify/simulation_gate.json")
if not gate.exists() or not json.loads(gate.read_text())["passed"]:
    parser.error("complete simulation/preservation gate must pass before PnR")
if args.attribute_candidate:
    provenance = json.loads((TASK / "runs/attribute-preserve-v1/rtl-provenance.json").read_text())
    candidate_hashes = {"hw/rtl/" + name: digest for name, digest in provenance["rtl_sha256"].items()}
else:
    candidate_hashes = json.loads((TASK / "verify/candidate_rtl_hashes.json").read_text())
different = [name for name, digest in candidate_hashes.items()
             if not (ROOT / name).is_file()
             or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
if different:
    parser.error(f"live RTL differs from verified candidate: {different}")
profile = "naive_th16_tcol16_m16_L16_bigmem_all_bram"
output = TASK / "runs" / args.postfix
output.mkdir(parents=True, exist_ok=False)
physical_postfix = args.postfix
if args.resume_postfix:
    previous = TASK / "runs" / args.resume_postfix
    prior_state = json.loads((previous / "state.json").read_text())
    physical_postfix = prior_state["command"][prior_state["command"].index("--postfix") + 1]
physical = ROOT / "build/hw/syn/xilinx/xrt" / (
    f"{profile}_{physical_postfix}_xilinx_u55c_gen3x16_xdma_3_202210_1_hw"
)
if physical.exists() and not args.resume_postfix:
    parser.error(f"physical output already exists: {physical}")
if args.resume_postfix:
    if str(physical) != prior_state["physical_output"]:
        parser.error("resume physical output does not match recorded wrapper command")
    if not physical.is_dir() or prior_state.get("returncode", 0) == 0:
        parser.error("resume requires a failed physical run")
    prior_hashes = json.loads((previous / "source_hashes.json").read_text())
    if any(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest
           for name, digest in prior_hashes.items() if name.startswith(("hw/rtl/", "configs/"))):
        parser.error("resume cannot reuse synthesis after RTL/config changes")
command = [str(ROOT / "build/hw/syn/xilinx/xrt/run_hw.sh"),
           "--config", profile, "--postfix", physical_postfix,
           "--slr-floorplan", "1", "--no-early-fail", "FAST_MODE=0"]
environment = os.environ.copy()
if args.resume_postfix:
    environment["VPP_FLAGS"] = "--from_step vpl.impl"
environment["PLATFORM"] = (
    "/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/"
    "xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm"
)
for key in ("PERF", "DEBUG"):
    environment.pop(key, None)
def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")
state = {"command": command, "started": now(), "physical_output": str(physical),
         "validation_gate": str(gate),
         "validation_gate_sha256": hashlib.sha256(gate.read_bytes()).hexdigest(),
         "platform": environment["PLATFORM"],
         "resume_from": args.resume_postfix,
         "target_mhz": 100, "state": "starting", "runner_pid": os.getpid()}
state_path = output / "state.json"
def save():
    state_path.write_text(json.dumps(state, indent=2) + "\n")
hashes = {}
for directory in (ROOT / "hw/rtl", ROOT / "hw/syn/xilinx/xrt"):
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.suffix in (".sv", ".v", ".vh", ".svh", ".tcl", ".mk", ".in", ".py"):
            hashes[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
config = ROOT / "configs" / (profile + ".sh")
hashes[str(config.relative_to(ROOT))] = hashlib.sha256(config.read_bytes()).hexdigest()
makefile = ROOT / "hw/syn/xilinx/xrt/Makefile"
hashes[str(makefile.relative_to(ROOT))] = hashlib.sha256(makefile.read_bytes()).hexdigest()
(output / "source_hashes.json").write_text(json.dumps(hashes, indent=2) + "\n")
save()
with (output / "wrapper.log").open("w") as log:
    process = subprocess.Popen(command, cwd=ROOT, env=environment,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    state.update(state="running", wrapper_pid=process.pid)
    save()
    result = process.wait()
state.update(state="finished", finished=now(), returncode=result)
state["changed_sources"] = [name for name, digest in hashes.items()
                            if not (ROOT / name).exists()
                            or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
save()
print(json.dumps(state), flush=True)
raise SystemExit(result)
