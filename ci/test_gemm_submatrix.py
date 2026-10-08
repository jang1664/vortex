#!/usr/bin/env python3
"""Exercise original-storage/target-region GEMM and fixed-capacity QK/PV jobs.

Run from any directory; simulations always run in the configured build directory.
The sequence cases reuse packed inputs while changing only execution extents.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import sys
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from ci.test_llm_regression import execute
from tools.latency_bench.perf_log import parse_fpga_cycle_stats
from tools.verify_rtl import check_pass, has_strict_failure


CASES = {
    "normal_m1": "-m 1 -n 256 -k 256",
    "normal_m4": "-m 4 -n 256 -k 256",
    "normal_m256": "-m 256 -n 256 -k 256",
    "kv_qk": "-m 1 -n 512 -k 128 -q 128 -t 1 -d 0 --target-n-list 256,288,320",
    "kv_pv": "-m 1 -n 128 -k 512 -q 128 -t 0 -d 1 --target-k-list 256,288,320",
    "kv_pv_1024": "-m 4 -n 128 -k 1024 -q 128 -d 1 --target-k-list 256,288,320",
    "qk_storage_tail": "-m 1 -n 320 -k 128 -q 128 -t 1 --target-n 288",
    "pv_storage_tail": "-m 1 -n 256 -k 320 -q 128 -d 1 --target-k 288",
    "partial_m": "-m 4 -n 128 -k 320 --target-m 1 --target-k 288",
    "partial_odd_m": "-m 3 -n 128 -k 320 --target-m 1 --target-k 288",
    "partial_m_multitile": "-m 3 -n 256 -k 320 --target-m 1 --target-k 288",
    "region_start": "-m 132 -n 256 -k 320 --m-start 128 --n-start 128 --target-m 1 --target-n 128 --target-k 288",
    "partial_n_beat": "-m 1 -n 128 -k 128 --target-n-list 16,48",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=REPO / "build")
    parser.add_argument("--config", type=Path, default=REPO / "configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh")
    parser.add_argument("--cases", default=",".join(CASES), help="Comma-separated case names")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--timeout", type=float, default=300, help="Seconds per wrapper invocation")
    parser.add_argument("--output", type=Path, default=REPO / "build" / ("gemm_submatrix_" + datetime.now().strftime("%Y%m%d_%H%M%S")))
    args = parser.parse_args()
    names = args.cases.split(",")
    if any(name not in CASES for name in names):
        parser.error("Unknown case; use --list")
    if args.list:
        for name in names:
            print(f"{name}: {CASES[name]} --tagged")
        return 0
    build, config, output = args.build_dir.resolve(), args.config.resolve(), args.output.resolve()
    if not (build / "ci/run_black.sh").is_file() or not config.is_file():
        parser.error("Configured build directory and existing config are required")
    output.mkdir(parents=True, exist_ok=False)
    # run_black.sh can reuse an existing simv without checking RTL timestamps.
    # Explicitly refresh it with the same PERF_ENABLE used by --perf 3.
    build_command = ["bash", "-c",
                     'source "$1" || exit; export CONFIGS="$CONFIGS -DPERF_ENABLE"; '
                     'export PATH="/usr/bin:$PATH"; exec make -C sim/xrtsim_vcs FSDB_DUMP=1 -W "$2" simv',
                     "gemm-submatrix-build", str(config), str(REPO / "sim/xrtsim_vcs/tb_vcs_xrtsim.sv")]
    print(f"BUILD RTL: {output / 'rtl-build.log'}", flush=True)
    if execute(build_command, build, output / "rtl-build.log", args.timeout) != 0:
        return 1
    results = []
    for name in names:
        case_args = CASES[name] + " --tagged"
        command = ["bash", "-c", 'source "$1" || exit; shift; exec "$@"', "gemm-submatrix",
                   str(config), "bash", "ci/run_black.sh", "xrt-vcs-sim",
                   "--app", "fpint_gemm_ffn_hw", "--args", case_args, "--perf", "3"]
        log = output / (name + ".log")
        print(f"RUN {name}: {case_args}\n  log: {log}", flush=True)
        start = time.monotonic()
        rc = execute(command, build, log, args.timeout)
        sim_log = build / "sim/xrtsim_vcs/simv.log"
        if sim_log.exists():
            shutil.copyfile(sim_log, output / (name + "-simv.log"))
        passed = rc == 0 and check_pass(log.read_text(errors="replace"))
        if sim_log.exists():
            passed = passed and not has_strict_failure(sim_log.read_text(errors="replace"))
        result = dict(name=name, args=case_args, passed=passed, returncode=rc,
                      seconds=round(time.monotonic() - start, 2), log=str(log),
                      cycle_scope="final job (device-close counters)",
                      **parse_fpga_cycle_stats(log))
        results.append(result)
        (output / "summary.json").write_text(json.dumps(dict(config=str(config), cases=results), indent=2) + "\n")
        print(f"{'PASS' if passed else 'FAIL'} {name}: {result['seconds']}s", flush=True)
        if not passed:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
