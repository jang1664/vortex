#!/usr/bin/env python3
"""Frozen-RTL, exact-config GEMM PERF class 3 comparison through run_black.sh.

Every experiment gets a new configured build and an immutable RTL snapshot.
MAKEFLAGS command-line RTL_DIR overrides keep subsequent runs independent from
concurrent RTL edits. No synthesis, cleanup, or production configuration edits.
"""

import argparse
from datetime import datetime
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "configs/improve_th32_tcol32_m32_t4_bigmem.sh"
CASES = {
    "smoke_qcol": "-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1",
    "overlap_d0_t0": "-m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1",
    "qrow": "-m 31 -n 64 -k 96 -q 32 -t 1 -d 1 -r 1",
    "odd_tail_qcol": "-m 3 -n 33 -k 33 -q 32 -t 0 -d 0 -r 1",
    "overlap_d0_t1": "-m 4 -n 256 -k 256 -q 32 -t 1 -d 0 -r 1",
    "overlap_d1_t0": "-m 4 -n 256 -k 256 -q 32 -t 0 -d 1 -r 1",
    "overlap_d1_t1": "-m 4 -n 256 -k 256 -q 32 -t 1 -d 1 -r 1",
}


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--extra", default="")
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--snapshot-only", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--recheck-existing", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_]+", args.variant):
        parser.error("Variant must be an alphanumeric build identifier")
    build = ROOT / f"build_gemm_depcuts_{args.variant}"
    evidence = build / "perf3-evidence"
    manifest_path = evidence / "manifest.json"
    if not args.resume:
        build.mkdir(exist_ok=False)
        evidence.mkdir()
        shutil.copytree(ROOT / "hw/rtl", evidence / "rtl")
        shutil.copy2(CONFIG, evidence / "config.sh")
        files = {str(p.relative_to(evidence / "rtl")): sha(p)
                 for p in sorted((evidence / "rtl").rglob("*")) if p.is_file()}
        manifest = {"variant": args.variant, "started_at": datetime.now().isoformat(),
                    "config": str(CONFIG), "config_sha256": sha(CONFIG),
                    "rtl_files": files, "extra": args.extra, "runs": [],
                    "rtl_manifest_sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
                    "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    "metric": "PERF: jobs=... total_cycles=... busy_cycles=... / GEMM_TOTAL_CYC",
                    "status": "snapshot_secured"}
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Snapshot secured: {manifest_path}", flush=True)
    else:
        manifest = json.loads(manifest_path.read_text())
        if manifest["extra"] != args.extra:
            parser.error("Resume extra defines differ from the frozen manifest")
    if args.snapshot_only:
        return 0
    base_configs = subprocess.check_output(
        ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"', "config",
         str(evidence / "config.sh")], text=True)
    env = dict(os.environ, SIMLIB_DIR=str(ROOT / "build/vcs_simlib"),
               CONFIGS=base_configs + " -DDISABLE_FSDB " + args.extra + " -DPERF_ENABLE",
               CC="/usr/bin/gcc", CXX="/usr/bin/g++",
               MAKEFLAGS=f"RTL_DIR={evidence / 'rtl'}")
    if not (build / "config.mk").exists():
        with (evidence / "configure.log").open("x") as log:
            subprocess.run(["../configure", "--xlen=64", "--tooldir=/opt/vortex",
                            "--prefix=" + str(Path.home() / "tools/vortex")],
                           cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    spec = importlib.util.spec_from_file_location("verify_rtl", ROOT / "tools/verify_rtl.py")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    if args.recheck_existing:
        for record in manifest["runs"]:
            prefix = evidence / f"{record['case']}-{record['repeat']}"
            app_text = prefix.with_suffix(".wrapper.log").read_text(errors="replace")
            counters = [dict(zip(("jobs", "total_cycles", "busy_cycles"), map(int, row)))
                        for row in re.findall(r"PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)", app_text)]
            record["gemm_perf"] = counters
            record["app_log_source"] = "wrapper_stdout"
            record["status"] = "pass" if record["returncode"] == 0 and verifier.check_pass(app_text) \
                and len(counters) == 1 and counters[0]["jobs"] > 0 and counters[0]["total_cycles"] > 0 \
                and not record["trace_failures"] else "fail"
        manifest.setdefault("measurement_notes", []).append(
            "Rechecked existing wrapper stdout: non-debug wrapper does not create build/run.log; "
            "initial missing-counter classification was a measurement parser error, not RTL failure.")
        manifest["status"] = "pass" if all(r["status"] == "pass" for r in manifest["runs"]) else "fail"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest["runs"]), flush=True)
        return 0 if manifest["status"] == "pass" else 1
    manifest["base_configs"] = base_configs
    manifest["makeflags"] = env["MAKEFLAGS"]
    manifest["status"] = "running"
    for case in args.case or CASES:
        for repeat in range(1, args.repeat + 1):
            if any(r["case"] == case and r["repeat"] == repeat for r in manifest["runs"]):
                continue
            prefix = evidence / f"{case}-{repeat}"
            shell = ('set -euo pipefail; source "$1"; export CONFIGS="$CONFIGS -DDISABLE_FSDB $2"; '
                     'export PATH="/usr/bin:$PATH"; exec timeout "$3" ci/run_black.sh '
                     'xrt-vcs-sim --app fpint_gemm_ffn_hw --args "$4" --perf 3')
            start = time.time()
            with prefix.with_suffix(".wrapper.log").open("x") as log:
                result = subprocess.run(["bash", "-c", shell, "measure-perf3", str(evidence / "config.sh"),
                                         args.extra, str(args.timeout), CASES[case]],
                                        cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT)
            app = build / "run.log"
            app_text = app.read_text(errors="replace") if app.exists() else prefix.with_suffix(".wrapper.log").read_text(errors="replace")
            if app.exists():
                shutil.copy2(app, prefix.with_suffix(".app.log"))
            counters = [dict(zip(("jobs", "total_cycles", "busy_cycles"), map(int, row)))
                        for row in re.findall(r"PERF: jobs=(\d+) total_cycles=(\d+) busy_cycles=(\d+)", app_text)]
            failures = []
            trace = build / "sim/xrtsim_vcs/simv.log"
            if trace.exists():
                with trace.open(errors="replace") as f:
                    for number, line in enumerate(f, 1):
                        if verifier.has_strict_failure(line) or re.search(r"Assertion.*failed|assertion failure|^Error-", line, re.I):
                            failures.append({"line": number, "text": line.rstrip()[:800]})
                with trace.open("rb") as src, gzip.open(prefix.with_suffix(".simv.log.gz"), "wb", compresslevel=1) as dst:
                    shutil.copyfileobj(src, dst)
            record = {"case": case, "repeat": repeat, "args": CASES[case], "returncode": result.returncode,
                      "app_log_source": "build/run.log" if app.exists() else "wrapper_stdout",
                      "elapsed_seconds": round(time.time() - start, 1), "gemm_perf": counters,
                      "trace_failures": failures,
                      "status": "pass" if result.returncode == 0 and verifier.check_pass(app_text)
                      and len(counters) == 1 and counters[0]["jobs"] > 0 and counters[0]["total_cycles"] > 0
                      and not failures else "fail"}
            simv = build / "sim/xrtsim_vcs/simv"
            if simv.exists():
                record["simv_sha256"] = sha(simv)
                record["simv_objects"] = {p.name: sha(p) for p in sorted(simv.with_name("simv.daidir").glob("*.so"))}
            app_dir = build / "tests/regression/fpint_gemm_ffn_hw"
            record["application_artifacts_sha256"] = {
                name: sha(app_dir / name) for name in ("kernel.vxbin", "fpint_gemm_ffn_hw")
                if (app_dir / name).exists()}
            manifest["runs"].append(record)
            manifest["status"] = "running" if record["status"] == "pass" else "fail"
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            print(json.dumps(record), flush=True)
            if record["status"] != "pass":
                return 1
    manifest["status"] = "pass"
    manifest["completed_at"] = datetime.now().isoformat()
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
