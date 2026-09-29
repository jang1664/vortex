#!/usr/bin/env python3
"""Run isolated MXU SLR kernel variants and retain deterministic evidence."""
import argparse
import concurrent.futures
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import threading

HERE = Path(__file__).resolve().parent
MAIN = HERE.parents[2]
spec = importlib.util.spec_from_file_location("verify_rtl", MAIN / "tools/verify_rtl.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
CASES = [(1, 0, 0, 1), (16, 0, 0, 1), (256, 0, 0, 1),
         (16, 1, 0, 1), (16, 0, 1, 1), (16, 1, 1, 1), (33, 0, 0, 2)]
OUTPUT_LOCK = threading.Lock()

def progress(message):
    with OUTPUT_LOCK:
        print(message, flush=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def tail(path, size=16 * 1024 * 1024):
    if not path.exists():
        return ""
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - size))
        return stream.read().decode(errors="replace")

def execute(argv, cwd, env, log, seconds):
    started = time.monotonic()
    with log.open("w") as stream:
        result = subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", str(seconds),
                                 *argv], cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
    return result.returncode, round(time.monotonic() - started, 2)

def run_variant(source, phase, backend, slr, cases, label=None, reuse_build_label=None):
    name = f"{label or phase}_{backend}_slr{slr}"
    out = HERE / "results" / name
    out.mkdir(parents=True, exist_ok=True)
    build_name = f"{reuse_build_label}_{backend}_slr{slr}" if reuse_build_label else name
    if reuse_build_label and build_name == name:
        raise RuntimeError("Reuse requires a new evidence label")
    build = source / f"build_mxu_{build_name}"
    build.mkdir(exist_ok=True)
    config = HERE / "configs" / ("th32_c1_improve_m32_tcol32.sh" if backend == "improve"
                                else "th32_c1_naive_m32_tcol32.sh")
    configs = subprocess.check_output(["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"',
                                      "bash", str(config)], text=True)
    tokens = shlex.split(configs)
    if backend == "naive_noacc":
        tokens.remove("-DGEMM_NAIVE_USE_ACC_MEM")
    if slr:
        tokens.append("-DGEMM_SLR_PIPELINE")
    if phase != "baseline":
        tokens.append("-DDISABLE_FSDB")
    configs = " ".join(tokens)
    env = os.environ.copy()
    env.update(CONFIGS=configs, CC="/usr/bin/gcc", CXX="/usr/bin/g++", DEBUG_LEVEL="1",
               VCS_CPPFLAGS="-DDEBUG_LEVEL=1", THIRD_PARTY_DIR=str(MAIN / "third_party"),
               SIMLIB_DIR=str(MAIN / "build/vcs_simlib"),
               XILINX_IP_DIR=str(MAIN / "build/sim/xrtsim_vcs/xilinx_ip"))
    configure = ["../configure", "--xlen=64", "--tooldir=/opt/vortex",
                 f"--prefix={Path.home()}/tools/vortex"]
    host_paths = [source / "tests/regression" / app / "main.cpp"
                  for app in ("fpint_gemm_ffn_hw", "fpint_gemm_ffn_hw_naive")]
    host_hashes = {str(p): digest(p) for p in host_paths}
    metadata = dict(name=name, source=str(source), build=str(build), configs=configs,
                    config_file=str(config), config_sha256=digest(config),
                    source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
                    rtl_sha256=digest(source / "hw/rtl/core/gemm/VX_gemm_unit.sv"),
                    host_source_sha256=host_hashes, reused_build_label=reuse_build_label,
                    configure=configure, env={k: env[k] for k in ["CC", "CXX", "DEBUG_LEVEL", "VCS_CPPFLAGS", "THIRD_PARTY_DIR", "SIMLIB_DIR", "XILINX_IP_DIR"]})
    metadata_path = out / "metadata.json"
    if metadata_path.exists():
        prior = json.loads(metadata_path.read_text())
        if prior["rtl_sha256"] != metadata["rtl_sha256"] or prior["configs"] != configs:
            raise RuntimeError(f"{name}: existing simulator build belongs to different source/config; use a new --label")
    if reuse_build_label:
        prior = json.loads((HERE / "results" / build_name / "metadata.json").read_text())
        if prior["rtl_sha256"] != metadata["rtl_sha256"] or prior["configs"] != configs:
            raise RuntimeError(f"{name}: reused simulator has a different RTL/config fingerprint")
        if not (build / "config.mk").exists():
            raise RuntimeError(f"{name}: reused build is not configured")
        metadata["simv_sha256"] = digest(build / "sim/xrtsim_vcs/simv")
    else:
        code, duration = execute(configure, build, env, out / "configure.log", 300)
        if code:
            raise RuntimeError(f"{name}: configure failed {code}")
    app = "fpint_gemm_ffn_hw" if backend == "improve" else "fpint_gemm_ffn_hw_naive"
    if reuse_build_label:
        host_build = ["make", "-B", "-C", str(build / "tests/regression" / app), app, "DEBUG=1"]
        metadata["explicit_host_rebuild"] = host_build
        code, _ = execute(host_build, build, env, out / "host-rebuild.log", 300)
        if code:
            raise RuntimeError(f"{name}: explicit host application rebuild failed {code}")
    (out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    records = []
    for m, t, d, r in cases:
        case = f"m{m}_t{t}_d{d}_r{r}"
        argv = [str(source / "ci/run_black.sh"), "xrt-vcs-sim", "--app", app,
                "--args", f"-m {m} -k 256 -n 256 -q 32 -t {t} -d {d} -r {r}", "--debug", "1"]
        for attempt, seconds in enumerate((300, 1800), 1):
            if digest(source / "hw/rtl/core/gemm/VX_gemm_unit.sv") != metadata["rtl_sha256"]:
                raise RuntimeError(f"{name}: RTL changed after metadata capture; use a fresh build label")
            if any(digest(p) != host_hashes[str(p)] for p in host_paths):
                raise RuntimeError(f"{name}: host source changed before case execution")
            log = out / f"{case}.attempt{attempt}.log"
            progress(f"START {name} {case} attempt={attempt}")
            code, duration = execute(argv, build, env, log, seconds)
            if digest(source / "hw/rtl/core/gemm/VX_gemm_unit.sv") != metadata["rtl_sha256"]:
                raise RuntimeError(f"{name}: RTL changed during case execution; result is not valid acceptance evidence")
            if any(digest(p) != host_hashes[str(p)] for p in host_paths):
                raise RuntimeError(f"{name}: host source changed during case execution")
            if reuse_build_label and digest(build / "sim/xrtsim_vcs/simv") != metadata["simv_sha256"]:
                raise RuntimeError(f"{name}: reused simulator binary changed during case execution")
            app_text = tail(log)
            applog = build / "run.log"
            saved_applog = out / f"{case}.attempt{attempt}.app.log"
            if applog.exists():
                shutil.copyfile(applog, saved_applog)
                app_text += "\n" + tail(saved_applog)
            simlog = build / "sim/xrtsim_vcs/simv.log"
            saved_simlog = out / f"{case}.attempt{attempt}.simv.log"
            if simlog.exists():
                shutil.copyfile(simlog, saved_simlog)
            sim_text = tail(saved_simlog)
            # Trace contains signal names such as error; require actual diagnostic syntax.
            fatal = bool(re.search(r"Fatal:|Error-|^ERROR[: ]|Assertion.*fail|\$fatal", app_text + sim_text, re.M))
            passed = code == 0 and verify.check_pass(app_text) and not fatal
            entry = dict(variant=name, case=case, attempt=attempt, timeout_seconds=seconds,
                         returncode=code, duration_seconds=duration, passed=passed,
                         command=argv, log=str(log), applog=str(saved_applog), simlog=str(saved_simlog), fatal=fatal)
            entry["source_hashes_verified_before_after"] = True
            entry["rtl_sha256"] = metadata["rtl_sha256"]
            entry["host_source_sha256"] = host_hashes
            entry["errors"] = "" if passed else verify.extract_errors(app_text + "\n" + sim_text)
            # Use the shared deterministic report schema as well as richer runner metadata.
            capture = io.StringIO()
            with OUTPUT_LOCK:
                with contextlib.redirect_stdout(capture):
                    verify.report("pass" if passed else "fail", f"{name}/{case}", entry["errors"], str(log))
            entry["verification_report"] = json.loads(capture.getvalue())
            records.append(entry)
            (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
            progress(f"END {name} {case} rc={code} pass={passed} seconds={duration}")
            if code != 124 or attempt == 2:
                break
            # A nonempty fresh log and ongoing compile/runtime activity justify one longer retry.
            progressing = bool(re.search(r"g\+\+|gcc |Parsing|Compiling|cycles|[0-9]+:|vhdlan|vcs -", app_text + sim_text))
            if not progressing:
                break
        if code and not simlog.exists():
            progress(f"BUILD FAILURE {name}; remaining cases cannot execute")
            break
    return records

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["baseline", "final", "reproduce"])
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--backend", choices=["naive_acc", "naive_noacc", "improve"])
    parser.add_argument("--slr", type=int, choices=[0, 1])
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--label", help="Unique evidence/build prefix for a revised RTL run")
    parser.add_argument("--case", help="Run only a case key such as m256_t0_d0_r1")
    parser.add_argument("--prioritize-case", help="Execute this matrix case first")
    parser.add_argument("--cases", nargs="+", help="Execute a selected list of case keys")
    parser.add_argument("--reuse-build-label", help="Reuse matching configured RTL builds while rebuilding host apps")
    args = parser.parse_args()
    cases = [(16, 0, 0, 1)] if args.phase == "baseline" else CASES
    if args.cases:
        mapping = {f"m{c[0]}_t{c[1]}_d{c[2]}_r{c[3]}": c for c in cases}
        if any(c not in mapping for c in args.cases):
            parser.error("Unknown case key")
        cases = [mapping[c] for c in args.cases]
    if args.case:
        cases = [c for c in cases if f"m{c[0]}_t{c[1]}_d{c[2]}_r{c[3]}" == args.case]
        if not cases:
            parser.error("Unknown case key")
    if args.prioritize_case:
        cases = sorted(cases, key=lambda c: f"m{c[0]}_t{c[1]}_d{c[2]}_r{c[3]}" != args.prioritize_case)
    backends = [args.backend] if args.backend else ["naive_acc", "naive_noacc", "improve"]
    slrs = [args.slr] if args.slr is not None else ([0] if args.phase != "final" else [0, 1])
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_variant, args.source.resolve(), args.phase, b, s, cases, args.label, args.reuse_build_label)
                   for b in backends for s in slrs]
        all_results = [item for future in futures for item in future.result()]
    (HERE / "results" / f"{args.label or args.phase}_summary.json").write_text(json.dumps(all_results, indent=2) + "\n")
    print(f"TOTAL {sum(r['passed'] for r in all_results)}/{len(all_results)} attempts passed", flush=True)
    latest = {(r["variant"], r["case"]): r for r in all_results}
    expected = len(backends) * len(slrs) * len(cases)
    passed_cases = sum(r["passed"] for r in latest.values())
    print(f"CASES {passed_cases}/{expected} passed after final attempts", flush=True)
    return 0 if len(latest) == expected and passed_cases == expected else 1

if __name__ == "__main__":
    sys.exit(main())
