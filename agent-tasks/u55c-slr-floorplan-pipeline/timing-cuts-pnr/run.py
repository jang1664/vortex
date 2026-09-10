#!/usr/bin/env python3
"""User-requested fresh TH32 timing-cut PnR; no retry or RTL modification.

The user explicitly requested these physical runs after the timing-cut and
structural-hook changes. This runner records source identity, not a claim of
a new exact-config simulation gate. Historical verification is in sibling tasks.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--count", type=int, choices=(4, 8))
    selection.add_argument("--config", type=Path)
    parser.add_argument("--postfix", required=True)
    parser.add_argument("--monitor-interval", type=int, default=3600,
                        help="Requested status interval in seconds (metadata only)")
    args = parser.parse_args()
    if args.monitor_interval < 1:
        parser.error("monitor interval must be positive")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.postfix):
        parser.error("invalid postfix")
    root = Path(__file__).resolve().parents[3]
    if args.config is not None:
        config = (root / args.config).resolve()
        if not config.is_file() or config.parent != root / "configs":
            parser.error("config must be an existing source config in configs/")
        profile = config.stem.removeprefix("improve_")
    else:
        config = root / f"configs/improve_th32_tcol32_m32_t{args.count}_bigmem.sh"
        profile = f"th32_t{args.count}"
    platform_name = "xilinx_u55c_gen3x16_xdma_3_202210_1"
    platform = Path("/opt/xilinx/platforms") / platform_name / f"{platform_name}.xpfm"
    for tool in ("bash", "make", "vivado", "v++", "platforminfo"):
        if not shutil.which(tool):
            parser.error(f"missing tool: {tool}")
    if not platform.is_file():
        parser.error(f"missing platform: {platform}")
    # Match run_hw.sh: start at 100 MHz, then allow the sourced config to
    # override CLOCK_FREQ_HZ (despite its historical name, the unit is MHz).
    clock_value = subprocess.check_output(
        ["bash", "-c", 'set -euo pipefail; CLOCK_FREQ_HZ=100; source "$1"; '
         'printf "%s" "$CLOCK_FREQ_HZ"', "pnr-clock", str(config)],
        cwd=root, text=True).strip()
    if not re.fullmatch(r"[1-9][0-9]*", clock_value):
        parser.error("config clock must be a positive integer in MHz")
    tag = f"{profile}_{args.postfix}"
    build = root / f"build_timing_cuts_pnr_{tag}"
    evidence = root / "build_timing_cuts_pnr_artifacts" / tag
    if build.exists() or evidence.exists():
        parser.error("build/evidence already exists; choose a new postfix")
    build.mkdir()
    evidence.mkdir(parents=True)
    xrt = build / "hw/syn/xilinx/xrt"
    output = xrt / f"{config.stem}_{args.postfix}_{platform_name}_hw"
    state = dict(status="configuring", started=now(), runner_pid=os.getpid(),
                 config=str(config), config_sha256=digest(config),
                 git_head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                 build=str(build), output=str(output),
                 log=str(evidence / "build.log"),
                 xclbin=str(output / "bin/vortex_afu.xclbin"),
                 postfix=args.postfix, clock_mhz=int(clock_value), source_based=True,
                 dcp_retry=False, monitoring_interval_seconds=args.monitor_interval)

    def save():
        temporary = evidence / "state.json.tmp"
        temporary.write_text(json.dumps(state, indent=2) + "\n")
        temporary.replace(evidence / "state.json")

    save()
    try:
        sources = [p for p in (root / "hw/rtl").rglob("*")
                   if p.is_file() and p.suffix in (".sv", ".v", ".vh", ".svh")]
        sources += [p for p in (root / "hw/syn/xilinx/xrt").iterdir() if p.is_file()]
        # Config variants may source a base config. Record the complete config
        # set so an untracked inherited file is not missing from the manifest.
        sources += list((root / "configs").glob("*.sh"))
        sources += [root / "configure", root / "config.mk.in"]
        manifest = {str(p.relative_to(root)): digest(p) for p in sorted(set(sources))}
        (evidence / "sources.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copyfile(config, evidence / config.name)
        (evidence / "worktree.patch").write_bytes(subprocess.check_output(
            ["git", "diff", "HEAD", "--", "hw", "configs"], cwd=root))
        environment = os.environ.copy()
        platform_paths = ["/opt/xilinx/platforms", *environment.get("PLATFORM_REPO_PATHS", "").split(":")]
        environment["PLATFORM_REPO_PATHS"] = ":".join(dict.fromkeys(p for p in platform_paths if p))
        # Keep the source config's directives, with no inherited debug/fast mode.
        environment.update(FAST_MODE="0", DEBUG="", PERF="", PROFILE="", SCOPE="",
                           GEMM_SLR_FLOORPLAN="0", PLACE_DESIGN_DIRECTIVE="Explore",
                           ROUTE_DESIGN_DIRECTIVE="AlternateCLBRouting", IMPL_ULTRATHREADS="0")
        with (evidence / "build.log").open("x") as log:
            result = subprocess.run(
                ["bash", "-c", 'set -euo pipefail; source "$1"; '
                 '../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"',
                 "pnr-configure", str(config)], cwd=build, env=environment,
                stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                state.update(status="configure_failed", returncode=result.returncode, finished=now())
                save()
                return result.returncode
            changed = [name for name, sha in manifest.items() if digest(root / name) != sha]
            if changed:
                raise RuntimeError(f"source changed during configure: {changed[:8]}")
            command = ["bash", "./run_hw.sh", "--config", str(config),
                       "--postfix", args.postfix, "--no-early-fail"]
            process = subprocess.Popen(command, cwd=xrt, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT)
            state.update(status="running", build_pid=process.pid, launched=now(), command=command)
            save()
            returncode = process.wait()
        state.update(status="complete" if returncode == 0 else "failed", returncode=returncode,
                     finished=now(), xclbin_exists=Path(state["xclbin"]).is_file())
        save()
        return returncode
    except Exception as error:
        state.update(status="runner_failed", finished=now(), error=f"{type(error).__name__}: {error}")
        save()
        raise


if __name__ == "__main__":
    raise SystemExit(main())
