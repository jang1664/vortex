#!/usr/bin/env python3
"""Reproducible xrt-vcs-only pre-PnR capacity/GEMM validation matrix."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify_rtl", ROOT / "tools/verify_rtl.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
GROUPS = {
  "c1": ("build_lmem_capacity_c1", "tcu_th16_c1_v2.sh", [
      ("capacity", "lmem_capacity", "", None),
      ("tcu", "sgemm_tcu", "-m 32 -n 32 -k 32", None)]),
  "c2": ("build_lmem_capacity_verify", "naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh", [
      ("capacity", "lmem_capacity", "", None),
      ("tcu", "sgemm_tcu", "-m 32 -n 32 -k 32", None)]),
  "c3": ("build_lmem_capacity_c3", "naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh", [
      ("capacity", "lmem_capacity", "", None)]),
  "c4": ("build_lmem_capacity_c4", "improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh", [
      ("capacity", "lmem_capacity", "", None)]),
}
parser = argparse.ArgumentParser()
parser.add_argument("group", choices=GROUPS)
args = parser.parse_args()
build_name, config_name, cases = GROUPS[args.group]
cases = list(cases)
if args.group in ("c2", "c3", "c4"):
    app = "fpint_gemm_ffn_hw" if args.group == "c4" else "fpint_gemm_ffn_hw_naive"
    for direction in (0, 1):
        for transpose in (0, 1):
            shape = "-m 2 -n 32 -k 128" if transpose == 0 else "-m 2 -n 160 -k 160"
            options = f"{shape} -q 32 -d {direction} -t {transpose} -r 2"
            if args.group in ("c2", "c3"):
                options += " --lmem-offset 1048576 --tagged"
            cases.append((f"gemm_d{direction}_t{transpose}", app, options, None))
    if args.group in ("c2", "c3"):
        cases.append(("offset_zero", app, "-m 2 -n 32 -k 128", None))
        for name, value in (("capacity", "1572864"), ("over_capacity", "1572865"),
                            ("almost_end", "1572863")):
            cases.append(("reject_" + name, app, "--lmem-offset " + value,
                          "LMEM layout does not fit device local memory"))
        for name, value in (("negative", "-1"), ("overflow", "18446744073709551616"),
                            ("trailing", "1048576x"), ("empty", "''")):
            cases.append(("reject_" + name, app, "--lmem-offset " + value,
                          "Invalid --lmem-offset:"))

build = ROOT / build_name
config = ROOT / "configs" / config_name
env = os.environ.copy()
env["SIMLIB_DIR"] = str(ROOT / "build/vcs_simlib")
env["XILINX_IP_DIR"] = str(ROOT / "build_lmem_capacity_verify/sim/xrtsim_vcs/xilinx_ip")
results = []
for name, app, options, rejection in cases:
    logfile = OUTPUT / f"{args.group}_{name}.log"
    command = ["ci/run_black.sh", "xrt-vcs-sim", "--app", app, "--args", options]
    shell = f"source {shlex.quote(str(config))}\n" + shlex.join(command)
    print(f"RUN {args.group}/{name}", flush=True)
    with logfile.open("w") as stream:
        try:
            rc = subprocess.run(["bash", "-c", shell], cwd=build, env=env,
                                stdout=stream, stderr=subprocess.STDOUT, timeout=1800).returncode
        except subprocess.TimeoutExpired:
            rc = 124
    text = logfile.read_text(errors="replace")
    passed = (rc != 0 and rejection in text and not verify.has_strict_failure(text)) if rejection else (rc == 0 and verify.check_pass(text))
    result = dict(case=name, passed=passed, returncode=rc, log=str(logfile),
                  command=shell, config_sha256=hashlib.sha256(config.read_bytes()).hexdigest())
    results.append(result)
    (OUTPUT / f"{args.group}_matrix.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"{'PASS' if passed else 'FAIL'} {args.group}/{name} rc={rc}", flush=True)
    if not passed:
        raise SystemExit(1)
