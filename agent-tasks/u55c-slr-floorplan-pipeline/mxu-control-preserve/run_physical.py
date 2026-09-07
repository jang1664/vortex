#!/usr/bin/env python3
"""Fresh source-based TH32/t4 or t8 synthesis and PnR with a current-RTL gate.

Run only after the task's simulation gate passes and the main agent authorizes
launch. This never reads an existing DCP or retries implementation. Each count
and postfix receives a new configured build directory and immutable evidence.
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
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def rtl_manifest(root):
    return {
        str(path.relative_to(root)): digest(path)
        for path in sorted((root / "hw/rtl").rglob("*"))
        if path.is_file() and path.suffix in (".sv", ".v", ".vh", ".svh")
    }


def check_gate(root, gate_path):
    gate = json.loads(gate_path.read_text())
    profiles = gate.get("profiles", [])
    if gate.get("status") != "pass" or len(profiles) != 2:
        raise ValueError("both current-RTL TH32 simulation profiles must pass")
    if gate.get("blackbox_mode") != "xrt-vcs-sim" or gate.get("total_functional_runs") != 14:
        raise ValueError("the 14-case xrt-vcs-sim preflight is required")
    directed = gate.get("directed", {})
    directed_runs = directed.get("runs", [])
    if directed.get("status") != "pass" or len(directed_runs) != 4:
        raise ValueError("four directed SLR/non-SLR register checks must pass")
    expected_directed = {(f"th32_t{count}", mode) for count in (4, 8) for mode in ("slr", "non-slr")}
    if {(run.get("profile"), run.get("mode")) for run in directed_runs} != expected_directed:
        raise ValueError("directed gate must cover t4/t8 with SLR and non-SLR RTL")
    for run in directed_runs:
        if run.get("status") != "pass" or digest(root / run["report"]) != run.get("report_sha256"):
            raise ValueError("directed register check failed or report identity changed")
        if run.get("extraction", {}).get("source_sha256") != digest(root / "hw/rtl/core/gemm/VX_gemm_compute_core.sv"):
            raise ValueError("directed checks used stale compute-core RTL")
    expected = {f"configs/improve_th32_tcol32_m32_t{count}_bigmem.sh" for count in (4, 8)}
    if {profile.get("config") for profile in profiles} != expected:
        raise ValueError("simulation gate must cover the exact TH32/t4 and TH32/t8 configs")
    for profile in profiles:
        if profile.get("status") != "pass" or digest(root / profile["config"]) != profile.get("final_config_sha256"):
            raise ValueError(f"simulation config gate is stale or failed: {profile.get('profile')}")
        suites = profile.get("suites", [])
        if len(suites) != 2 or sorted(len(suite.get("runs", [])) for suite in suites) != [3, 4]:
            raise ValueError(f"expected 4+3 test cases: {profile.get('profile')}")
        for suite in suites:
            if suite.get("returncode") != 0 or digest(root / suite["summary"]) != suite.get("summary_sha256"):
                raise ValueError("simulation suite failed or summary identity changed")
            for run in suite["runs"]:
                metrics = run.get("response_slot_metrics", {})
                if (run.get("status") != "pass" or run.get("returncode") != 0
                        or run.get("trace_failures") != [] or not metrics
                        or not all(metric.get("complete_and_balanced") for metric in metrics.values())):
                    raise ValueError(f"numerical/strict trace/slot check failed: {run.get('case')}")
    current = rtl_manifest(root)
    verified = gate.get("rtl_sources", {})
    if not verified or current != verified:
        changed = sorted(key for key in current.keys() | verified.keys() if current.get(key) != verified.get(key))
        raise ValueError(f"simulation RTL gate is stale or incomplete ({len(changed)} files): {changed[:8]}")
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, choices=(4, 8), required=True)
    parser.add_argument("--postfix", required=True)
    parser.add_argument("--check-only", action="store_true", help="validate gate/tools/unused output without creating anything")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.postfix):
        parser.error("postfix must be a safe filename component")

    task = Path(__file__).resolve().parent
    root = task.parents[2]
    gate_path = task / "simulation-manifest.json"
    try:
        rtl_sources = check_gate(root, gate_path)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    config = root / "configs" / f"improve_th32_tcol32_m32_t{args.count}_bigmem.sh"
    platform = Path("/opt/xilinx/platforms/xilinx_u55c_gen3x16_xdma_3_202210_1/"
                    "xilinx_u55c_gen3x16_xdma_3_202210_1.xpfm")
    tools = {name: shutil.which(name) for name in ("make", "bash", "vivado", "v++", "platforminfo")}
    if not all(tools.values()):
        parser.error(f"missing tools: {[name for name, path in tools.items() if not path]}")
    if not platform.is_file():
        parser.error(f"missing platform: {platform}")
    tag = f"th32_t{args.count}_{args.postfix}"
    build = root / f"build_mxu_control_pnr_{tag}"
    evidence = root / "build_mxu_control_pnr_artifacts" / tag
    prefix = f"{config.stem}_{args.postfix}"
    xrt = build / "hw/syn/xilinx/xrt"
    output = xrt / f"{prefix}_{platform.stem}_hw"
    for path in (build, evidence):
        if path.exists():
            parser.error(f"preserve existing path: {path}; choose a new postfix")
    if args.check_only:
        print(f"PASS: current RTL/config simulation gate, tools, platform, fresh paths: {tag}")
        return 0

    evidence.mkdir(parents=True, exist_ok=False)
    state_file = evidence / "state.json"
    state = {
        "status": "preparing", "started": now(), "runner_pid": os.getpid(),
        "config": str(config), "config_sha256": digest(config),
        "simulation_gate_sha256": digest(gate_path), "rtl_file_count": len(rtl_sources),
        "build": str(build), "output": str(output), "postfix": args.postfix,
        "xclbin": str(output / "bin/vortex_afu.xclbin"),
        "platform": str(platform), "clock_mhz": 100, "tools": tools,
        "log": str(evidence / "build.log"),
        "source_based_fresh_build": True, "dcp_retry": False,
    }

    def save():
        temporary = state_file.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(state_file)

    save()
    try:
        build.mkdir(exist_ok=False)
        paths = [root / relative for relative in rtl_sources]
        paths += [path for path in (root / "hw/syn/xilinx/xrt").rglob("*") if path.is_file() and "__pycache__" not in path.parts]
        paths += [root / "configure", root / "config.mk.in", config, Path(__file__).resolve()]
        manifest = {str(path.relative_to(root)): digest(path) for path in sorted(set(paths)) if path.is_file()}
        (evidence / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copyfile(gate_path, evidence / "simulation-manifest.json")
        shutil.copyfile(config, evidence / config.name)
        state.update(source_manifest_sha256=digest(evidence / "sources.json"), status="configuring")
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
            # A concurrent source edit during configure must never use an old test gate.
            check_gate(root, gate_path)
            changed = [relative for relative, sha in manifest.items() if digest(root / relative) != sha]
            if changed:
                raise ValueError(f"source changed during configure: {changed[:8]}")
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
        state.update(status="complete" if result == 0 else "failed", returncode=result,
                     finished=now(), xclbin_exists=Path(state["xclbin"]).is_file())
        save()
        return result
    except Exception as error:
        state.update(status="runner_failed", error=f"{type(error).__name__}: {error}", finished=now())
        save()
        raise


if __name__ == "__main__":
    raise SystemExit(main())
