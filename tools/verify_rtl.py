#!/usr/bin/env python3
"""
verify_rtl.py — Deterministic RTL verification runner.

Runs compilation + simulation, parses logs, outputs a structured JSON report.
Used by the rtl-improve loop skill.

Usage:
    # unittest (e.g., gemm_node_improve)
    python verify_rtl.py unittest --path hw/unittest/gemm_node_improve \
        --sim vcs --params "M=32 N=32 K=128 QBLK=32"

    # unittest with extra sim args
    python verify_rtl.py unittest --path hw/unittest/gemm_node_improve \
        --sim vcs --params "M=32 N=32 K=128 QBLK=32" \
        --extra-sim-args "+WTRANS=0 +QDIR=0"

    # unittest regression via test.sh
    python verify_rtl.py unittest --path hw/unittest/gemm_node_improve \
        --sim vcs --test-sh-mode qcol

    # blackbox test
    python verify_rtl.py blackbox --driver rtlsim --app vecadd \
        --app-args "-n 128" --cores 1

Output: JSON to stdout
    {
        "status": "pass" | "compile_error" | "sim_fail",
        "test_name": "...",
        "error_log": "...",
        "log_file": "..."
    }
"""

import argparse
import json
import os
import subprocess
import sys
import re

# Patterns that indicate pass in simulation logs
PASS_PATTERNS = [
    "OUTPUT CHECK PASSED",
    "STREAM SMOKE PASSED",
    "STREAM GEMM PASSED",
    "TEST PASSED",
    "PASSED",
]

# Patterns that indicate errors (for log extraction)
ERROR_PATTERNS = [
    r"Fatal:",
    r"ERROR",
    r"Error-",
    r"OUTPUT CHECK FAILED",
    r"mismatch",
    r"\*E,",          # VCS compile error
    r"Syntax error",
]

LOG_EXCERPT_LINES = 60


def run_cmd(cmd, cwd=None, timeout=600):
    """Run a shell command, return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd, timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True,
        )
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired:
        return -1, f"TIMEOUT after {timeout}s"


def extract_errors(log_text, max_lines=LOG_EXCERPT_LINES):
    """Extract lines matching error patterns from log text."""
    lines = log_text.splitlines()
    error_lines = []
    pattern = re.compile("|".join(ERROR_PATTERNS), re.IGNORECASE)
    for i, line in enumerate(lines):
        if pattern.search(line):
            # Include some context: 2 lines before, the match, 2 lines after
            start = max(0, i - 2)
            end = min(len(lines), i + 3)
            for j in range(start, end):
                ctx = lines[j]
                if ctx not in error_lines:
                    error_lines.append(ctx)
    if not error_lines:
        # No pattern match — return last N lines
        error_lines = lines[-max_lines:]
    return "\n".join(error_lines[-max_lines:])


def check_pass(log_text):
    """Check if any pass pattern exists in log text."""
    for pat in PASS_PATTERNS:
        if pat in log_text:
            return True
    return False


def find_log_file(test_dir, test_name=None):
    """Find the most relevant simulation log file."""
    logs_dir = os.path.join(test_dir, "logs")
    if not os.path.isdir(logs_dir):
        return None

    # Try specific sim log first
    if test_name:
        sim_log = os.path.join(logs_dir, f"sim_{test_name}.log")
        if os.path.isfile(sim_log):
            return sim_log

    # Prefer the default simulation log over compile output.  Most unittest
    # Makefiles write to logs/sim.log, and a successful compile log does not
    # contain the simulation pass marker.
    sim_log = os.path.join(logs_dir, "sim.log")
    if os.path.isfile(sim_log):
        return sim_log

    # Fall back to compile log when simulation never started.
    compile_log = os.path.join(logs_dir, "compile.log")
    if os.path.isfile(compile_log):
        return compile_log

    # Fall back to any .log file, most recently modified
    logs = [os.path.join(logs_dir, f) for f in os.listdir(logs_dir) if f.endswith(".log")]
    if logs:
        return max(logs, key=os.path.getmtime)
    return None


def report(status, test_name, error_log="", log_file=""):
    """Print JSON report to stdout."""
    r = {
        "status": status,
        "test_name": test_name,
        "error_log": error_log,
        "log_file": log_file,
    }
    print(json.dumps(r, indent=2))


def resolve_path(path):
    """Resolve path relative to repo root."""
    if os.path.isabs(path):
        return path
    # Try relative to cwd
    if os.path.isdir(path):
        return os.path.abspath(path)
    # Try relative to repo root (find via git)
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
        candidate = os.path.join(root, path)
        if os.path.isdir(candidate):
            return candidate
    except subprocess.CalledProcessError:
        pass
    return os.path.abspath(path)


# ---------------------------------------------------------------------------
# Test runners
# ---------------------------------------------------------------------------

def run_unittest(args):
    """Run a unittest via make or test.sh."""
    test_dir = resolve_path(args.path)
    sim = args.sim or "vcs"

    if not os.path.isdir(test_dir):
        report("compile_error", args.path,
               error_log=f"Test directory not found: {test_dir}")
        return 1

    # If test.sh mode is specified, use test.sh
    if args.test_sh_mode:
        return run_unittest_test_sh(test_dir, sim, args.test_sh_mode)

    # Otherwise, run make compile + make run
    return run_unittest_make(test_dir, sim, args.params, args.extra_sim_args)


def run_unittest_make(test_dir, sim, params, extra_sim_args):
    """Run unittest via make compile + make run."""
    test_name = os.path.basename(test_dir)

    # Step 1: Compile
    compile_cmd = f"make compile SIM_EXEC={sim}"
    rc, output = run_cmd(compile_cmd, cwd=test_dir, timeout=300)

    if rc != 0:
        compile_log = os.path.join(test_dir, "logs", "compile.log")
        log_file = compile_log if os.path.isfile(compile_log) else ""
        log_text = output
        if log_file and os.path.isfile(log_file):
            with open(log_file) as f:
                log_text = f.read()
        report("compile_error", test_name,
               error_log=extract_errors(log_text),
               log_file=log_file)
        return 1

    # Step 2: Run
    run_cmd_str = f"make run SIM_EXEC={sim}"
    if params:
        run_cmd_str += f" {params}"
    if extra_sim_args:
        run_cmd_str += f' EXTRA_SIM_ARGS="{extra_sim_args}"'

    # Derive test name from params for log file lookup
    param_test_name = None
    if params:
        # Extract M, N, K values for log file name pattern
        parts = params.split()
        pdict = {}
        for p in parts:
            if "=" in p:
                k, v = p.split("=", 1)
                pdict[k] = v
        if "TEST" in pdict:
            param_test_name = pdict["TEST"]

    rc, output = run_cmd(run_cmd_str, cwd=test_dir, timeout=600)

    # Find log
    log_file = find_log_file(test_dir, param_test_name) or ""
    log_text = output
    if log_file and os.path.isfile(log_file):
        with open(log_file) as f:
            log_text = f.read()

    if check_pass(log_text):
        report("pass", param_test_name or test_name, log_file=log_file)
        return 0
    else:
        report("sim_fail", param_test_name or test_name,
               error_log=extract_errors(log_text),
               log_file=log_file)
        return 1


def run_unittest_test_sh(test_dir, sim, mode):
    """Run unittest via test.sh (regression)."""
    test_name = f"{os.path.basename(test_dir)}/{mode}"

    cmd = f"SIM_EXEC={sim} bash test.sh {mode}"
    rc, output = run_cmd(cmd, cwd=test_dir, timeout=3600)

    # Parse summary line: [RESULT] pass=N fail=M
    pass_count = 0
    fail_count = 0
    match = re.search(r"\[RESULT\]\s+pass=(\d+)\s+fail=(\d+)", output)
    if match:
        pass_count = int(match.group(1))
        fail_count = int(match.group(2))

    if fail_count == 0 and pass_count > 0:
        report("pass", test_name,
               error_log=f"All {pass_count} tests passed")
        return 0
    else:
        report("sim_fail", test_name,
               error_log=extract_errors(output),
               log_file="")
        return 1


def run_blackbox(args):
    """Run a blackbox test via ci/blackbox.sh."""
    # Find build directory
    repo_root = subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()
    build_dir = os.path.join(repo_root, "build")

    bb_script = os.path.join(build_dir, "ci", "blackbox.sh")
    if not os.path.isfile(bb_script):
        report("compile_error", f"blackbox/{args.app}",
               error_log=f"blackbox.sh not found at {bb_script}. "
                         "Run configure first.")
        return 1

    cmd = f"./ci/blackbox.sh --driver={args.driver} --app={args.app}"
    if args.app_args:
        cmd += f' --args="{args.app_args}"'
    if args.cores:
        cmd += f" --cores={args.cores}"
    if args.threads:
        cmd += f" --threads={args.threads}"

    test_name = f"blackbox/{args.driver}/{args.app}"
    rc, output = run_cmd(cmd, cwd=build_dir, timeout=1800)

    if rc == 0 and check_pass(output):
        report("pass", test_name)
        return 0
    elif rc != 0 and ("Error" in output or "Fatal" in output or "Syntax" in output):
        report("compile_error", test_name,
               error_log=extract_errors(output))
        return 1
    else:
        report("sim_fail", test_name,
               error_log=extract_errors(output))
        return 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Deterministic RTL verification runner")
    sub = parser.add_subparsers(dest="command", required=True)

    # unittest subcommand
    ut = sub.add_parser("unittest", help="Run a unittest")
    ut.add_argument("--path", required=True,
                    help="Path to unittest directory (absolute or relative to repo root)")
    ut.add_argument("--sim", default="vcs", choices=["vcs", "vlt"],
                    help="Simulator (default: vcs)")
    ut.add_argument("--params", default="",
                    help='Make params, e.g., "M=32 N=32 K=128 QBLK=32"')
    ut.add_argument("--extra-sim-args", default="",
                    help='Extra simulator plusargs, e.g., "+WTRANS=0 +QDIR=0"')
    ut.add_argument("--test-sh-mode", default="",
                    help="Run via test.sh with mode (e.g., qcol, qrow, all)")

    # blackbox subcommand
    bb = sub.add_parser("blackbox", help="Run a blackbox test")
    bb.add_argument("--driver", required=True,
                    help="Driver: simx, rtlsim, xrt_vcs, etc.")
    bb.add_argument("--app", required=True,
                    help="Test app name")
    bb.add_argument("--app-args", default="",
                    help="Arguments for the test app")
    bb.add_argument("--cores", type=int, default=None)
    bb.add_argument("--threads", type=int, default=None)

    args = parser.parse_args()

    if args.command == "unittest":
        sys.exit(run_unittest(args))
    elif args.command == "blackbox":
        sys.exit(run_blackbox(args))


if __name__ == "__main__":
    main()
