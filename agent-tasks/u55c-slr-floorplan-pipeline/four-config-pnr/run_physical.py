#!/usr/bin/env python3
"""One normal source-based TH32 U55C build, with durable launch/exit evidence.

Run only after four-profile simulation and hook preflight pass. This invokes
configure and make, never opens an existing DCP or retries implementation.
Separate t4/t8 build directories avoid generated-file races.
"""

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, choices=(4, 8), required=True)
    parser.add_argument("--postfix", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.postfix):
        parser.error("postfix must be a safe filename component")

    root = Path(__file__).resolve().parents[3]
    gate_path = Path(__file__).resolve().with_name("simulation-manifest.json")
    gate = json.loads(gate_path.read_text())
    if gate.get("status") != "pass" or len(gate.get("profiles", [])) != 4:
        parser.error("all four simulation profiles must pass before physical launch")
    for profile in gate["profiles"]:
        if profile.get("status") != "pass" or digest(root / profile["config"]) != profile["final_config_sha256"]:
            parser.error(f"simulation gate is stale or failed: {profile.get('profile')}")
    config = root / "configs" / f"improve_th32_tcol32_m32_t{args.count}_bigmem.sh"
    platform = Path("/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/"
                    "xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm")
    for tool in ("make", "bash", "vivado", "v++", "platforminfo"):
        if not shutil.which(tool):
            parser.error(f"missing tool: {tool}")
    if not platform.is_file():
        parser.error(f"missing platform: {platform}")
    build = root / f"build_four_config_pnr_th32_t{args.count}"
    build.mkdir(exist_ok=True)
    evidence = root / "build_four_config_pnr_artifacts" / f"th32_t{args.count}_{args.postfix}"
    evidence.mkdir(parents=True, exist_ok=False)
    prefix = f"{config.stem}_{args.postfix}"
    xrt = build / "hw/syn/xilinx/xrt"
    output = xrt / f"{prefix}_{platform.stem}_hw"
    if output.exists():
        parser.error(f"preserve existing build: {output}; choose a new postfix")

    state = {
        "status": "configuring", "started": now(), "runner_pid": os.getpid(),
        "config": str(config), "config_sha256": digest(config),
        "simulation_gate_sha256": digest(gate_path),
        "build": str(build), "output": str(output),
        "xclbin": str(output / "bin/vortex_afu.xclbin"),
        "platform": str(platform), "clock_mhz": 100,
        "log": str(evidence / "build.log"),
    }
    state_file = evidence / "state.json"

    def save():
        temporary = state_file.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(state_file)

    # Source/config identity is recorded before the build can copy its inputs.
    paths = list((root / "hw/rtl").rglob("*.sv")) + list((root / "hw/rtl").rglob("*.v"))
    paths += list((root / "hw/rtl").rglob("*.vh")) + list((root / "hw/rtl").rglob("*.svh"))
    paths += [p for p in (root / "hw/syn/xilinx/xrt").iterdir() if p.is_file()]
    paths += [config]
    manifest = {str(p.relative_to(root)): digest(p) for p in sorted(set(paths))}
    (evidence / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
    save()
    with (evidence / "build.log").open("x") as log:
        configured = subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1"; '
             '../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"',
             "pnr-configure", str(config)], cwd=build, stdout=log, stderr=subprocess.STDOUT,
        )
        if configured.returncode:
            state.update(status="configure_failed", returncode=configured.returncode, finished=now())
            save()
            return configured.returncode
        command = ["make", f"PLATFORM={platform}", f"PREFIX={prefix}",
                   "TARGET=hw", "CLOCK_FREQ_HZ=100", "FAST_MODE=0",
                   "CONGESTION_FAIL_FAST=0", "GEMM_SLR_FLOORPLAN=1",
                   "PLACE_DESIGN_DIRECTIVE=Explore", "ROUTE_DESIGN_DIRECTIVE=AlternateCLBRouting",
                   "IMPL_ULTRATHREADS=0", "DEBUG=", "PERF=", "PROFILE=", "SCOPE="]
        process = subprocess.Popen(
            ["bash", "-c", 'set -euo pipefail; source "$1"; shift; exec "$@"',
             "pnr-source-build", str(config), *command], cwd=xrt,
            stdout=log, stderr=subprocess.STDOUT,
        )
        state.update(status="running", make_pid=process.pid, command=command, launched=now())
        save()
        result = process.wait()
    state.update(status="complete" if result == 0 else "failed",
                 returncode=result, finished=now(),
                 xclbin_exists=Path(state["xclbin"]).is_file())
    save()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
