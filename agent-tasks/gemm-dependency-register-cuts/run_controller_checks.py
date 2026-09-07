#!/usr/bin/env python3
"""Run deterministic controller dependency checks in configured comparison builds."""

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def main():
    records = []
    for cuts in (0, 1):
        build = ROOT / f"build_gemm_depcuts_cuts{cuts}"
        evidence = build / "perf3-evidence"
        if not (build / "config.mk").exists():
            raise RuntimeError(f"Unconfigured build: {build}")
        base = subprocess.check_output(["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"',
                                        "config", str(evidence / "config.sh")], text=True)
        env = dict(os.environ, CONFIGS=base + f" -DGEMM_TIMING_CUTS={cuts}",
                   CC="/usr/bin/gcc", CXX="/usr/bin/g++",
                   MAKEFLAGS=f"RTL_DIR={evidence / 'rtl'}")
        command = ["python3", str(ROOT / "tools/verify_rtl.py"), "unittest",
                   "--path", str(build / "hw/unittest/gemm_ctrl"), "--sim", "vcs",
                   "--extra-sim-args", "+SCHED_DIRECTED", "--timeout", "300"]
        log = evidence / "controller-directed.verify.json"
        with log.open("x") as f:
            result = subprocess.run(command, cwd=build, env=env, stdout=f, stderr=subprocess.STDOUT)
        record = {"cuts": cuts, "returncode": result.returncode, "log": str(log)}
        records.append(record)
        print(json.dumps(record), flush=True)
        if result.returncode:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
