#!/usr/bin/env python3
"""Configured VCS-only regression for the MXU SLR transport.

Run from any directory. Each variant has its own configured build directory
and simulator. Unit FP arithmetic uses FPNEW; xrt-vcs-sim kernel coverage uses
Xilinx IP separately. No source config is modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
VARIANTS = {
    "improve-off": ("improve", False, False),
    "improve-on": ("improve", True, False),
    "improve-wload-off": ("improve", False, True),
    "improve-wload-on": ("improve", True, True),
    "naive-acc-off": ("naive-acc", False, False),
    "naive-acc-on": ("naive-acc", True, False),
    "naive-lmem-off": ("naive-lmem", False, False),
    "naive-lmem-on": ("naive-lmem", True, False),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(VARIANTS))
    parser.add_argument("--report", type=Path, default=ROOT / "agent-tasks/mxu-slr-port/directed-results.json")
    args = parser.parse_args()
    for tool in ("vcs", "make", "python3", "bash"):
        if not shutil.which(tool):
            raise SystemExit(f"Missing required tool: {tool}")
    reports = []
    for name in args.variants:
        backend, slr, wload = VARIANTS[name]
        config_name = "improve" if backend == "improve" else "naive"
        config = (ROOT / "agent-tasks/mxu-slr-port/verification/configs"
                  / f"th32_c1_{config_name}_m32_tcol32.sh")
        defines = subprocess.check_output(
            ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"', "config", str(config)],
            text=True,
        ).split()
        if backend == "naive-lmem":
            defines.remove("-DGEMM_NAIVE_USE_ACC_MEM")
        if slr:
            defines.append("-DGEMM_SLR_PIPELINE")
        if wload:
            defines.append("-DWLOAD_AT_ONCE")
        env = os.environ.copy()
        env.update(CONFIGS=" ".join(defines), CC="/usr/bin/gcc", CXX="/usr/bin/g++")
        build = ROOT / f"build-mxu-directed-{name}"
        build.mkdir(exist_ok=True)
        saved = build / "directed-config.txt"
        if saved.exists() and saved.read_text().strip() != env["CONFIGS"]:
            raise SystemExit(f"Refusing to reuse changed variant configuration: {build}")
        saved.write_text(env["CONFIGS"] + "\n")
        shutil.copy2(config, build / "source-config.sh")
        configure = ["../configure", "--xlen=64", "--tooldir=/opt/vortex",
                     f"--prefix={Path.home()}/tools/vortex"]
        print(f"CONFIGURE {name}", flush=True)
        with (build / "configure.log").open("w") as log:
            subprocess.run(configure, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        command = ["python3", str(ROOT / "tools/verify_rtl.py"), "unittest", "--path",
                   str(build / "hw/unittest/mxu_slr"), "--sim", "vcs"]
        print(f"VERIFY {name}", flush=True)
        result = subprocess.run(command, cwd=build, env=env, capture_output=True, text=True)
        (build / "directed-report.json").write_text(result.stdout)
        (build / "driver-stderr.log").write_text(result.stderr)
        entry = {"variant": name, "command": command, "build": str(build), "exit_code": result.returncode,
                 "configs": env["CONFIGS"], "configure": configure,
                 "sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                            [ROOT / "hw/rtl/core/gemm/VX_gemm_unit.sv", ROOT / "hw/unittest/mxu_slr/tb_mxu_slr.sv",
                             ROOT / "hw/unittest/mxu_slr/Makefile", ROOT / "hw/unittest/mxu_slr/vcs.mk"]}}
        log = build / "hw/unittest/mxu_slr/logs/sim.log"
        text = log.read_text() if log.exists() else ""
        marker = re.search(r"PASSED MXU SLR directed vectors=(\d+) extra_delay=(\d+) latency=(\d+)\.\.(\d+) wload=(\d+)", text)
        entry["pass"] = (result.returncode == 0 and marker is not None
                         and re.search(r"Fatal:|Error-|ERROR|FAILED|mismatch", text, re.I) is None)
        entry["log"] = str(log)
        if marker:
            entry.update(zip(["vectors", "extra_delay", "latency_min", "latency_max", "wload"], map(int, marker.groups())))
            results = re.findall(r"^RESULT .+$", text, re.M)
            entry["results_sha256"] = hashlib.sha256("\n".join(results).encode()).hexdigest()
        if entry["pass"] and name == "naive-lmem-on":
            test_dir = build / "hw/unittest/mxu_slr"
            stress_log = test_dir / "logs/psum-stress.log"
            stress_cmd = [str(test_dir / "simv"), "+PSUM_STRESS", "-l", str(stress_log)]
            stress = subprocess.run(stress_cmd, cwd=test_dir, env=env,
                                    capture_output=True, text=True, timeout=300)
            (test_dir / "logs/psum-stress-stdout.log").write_text(stress.stdout + stress.stderr)
            stress_text = stress_log.read_text()
            stress_pass = (stress.returncode == 0
                           and "PASSED PSUM reservation stress accumulated_vectors=384" in stress_text
                           and re.search(r"Fatal:|Error-|ERROR|FAILED|mismatch", stress_text, re.I) is None)
            entry["psum_stress"] = {"pass": stress_pass, "exit_code": stress.returncode,
                                    "command": stress_cmd, "log": str(stress_log),
                                    "accumulated_vectors": 384}
            entry["pass"] &= stress_pass
            print(f"PSUM STRESS {'PASS' if stress_pass else 'FAIL'}", flush=True)
        reports.append(entry)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(reports, indent=2) + "\n")
        print(f"{'PASS' if entry['pass'] else 'FAIL'} {name}: {marker.group(0) if marker and result.returncode == 0 else result.stdout[-1500:]}", flush=True)
        if not entry["pass"]:
            raise SystemExit(1)
    if len({r["results_sha256"] for r in reports}) != 1:
        raise SystemExit("OFF/ON/backend numerical result streams differ")
    print(f"PASSED {len(reports)} variants; exact numerical result streams are identical", flush=True)


if __name__ == "__main__":
    main()
