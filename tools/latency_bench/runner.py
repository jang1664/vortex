from __future__ import annotations

import csv
import math
import os
import re
import shutil
import shlex
import subprocess
from datetime import datetime, timezone
from dataclasses import dataclass, replace
from pathlib import Path

import pandas as pd
import yaml

from .fpga_bins import FpgaBinConfig, resolve_fpga_bin, resolve_fpga_bin_config
from .progress import PROGRESS_COLUMNS
from .report import build_results, build_summary, sha256_file, write_manifest
from .suite import DEFAULT_BLACKBOX_ARGS, BenchCase, BenchSuite, suite_to_expanded_yaml, suite_to_rows


DEFAULT_SRUN_ARGS = (
    "--gres=fpga:u55c:1",
    "--cpus-per-task=4",
    "--mem=16G",
    # "--time=12:00:00",
)
DEFAULT_RETRY_MAX_ROUNDS = 5
DEFAULT_RETRY_TIMEOUT_GROWTH = 1.10
DEFAULT_RETRY_RESET_WAIT = "10s"
DEFAULT_RETRY_RESET_CMD = "xrt-smi reset"


@dataclass(frozen=True)
class ExecutionUnit:
    exec_key: str
    app: str
    args: str
    warmup: int
    iterations: int
    raw_csv: Path
    log_file: Path


@dataclass(frozen=True)
class RunOptions:
    build_dir: Path
    fpga_bin_dir: Path
    out_dir: Path
    platform: str
    xrt_device_index: int
    fpga_bin_label: str = ""
    configs: Path | None = None
    configs_extra: str = ""
    blackbox_args: tuple[str, ...] = DEFAULT_BLACKBOX_ARGS
    blackbox_timeout: str = ""
    srun: bool = True
    srun_args: tuple[str, ...] = DEFAULT_SRUN_ARGS
    dry_run: bool = False
    append_raw_csv: Path | None = None
    run_id: str | None = None
    skip_existing: bool = False
    prebuild: bool = True
    case_filters: tuple[str, ...] = ()
    retry: bool = False
    retry_max_rounds: int = DEFAULT_RETRY_MAX_ROUNDS
    retry_timeout_growth: float = DEFAULT_RETRY_TIMEOUT_GROWTH
    retry_reset_wait: str = DEFAULT_RETRY_RESET_WAIT
    retry_reset_cmd: str = DEFAULT_RETRY_RESET_CMD


@dataclass(frozen=True)
class GitMetadata:
    commit: str = ""
    branch: str = ""
    dirty: str = ""


def validate_inputs(options: RunOptions) -> None:
    if not options.build_dir.is_dir():
        raise FileNotFoundError(f"build directory not found: {options.build_dir}")
    blackbox = options.build_dir / "ci" / "blackbox.sh"
    if not blackbox.exists():
        raise FileNotFoundError(f"configured blackbox.sh not found: {blackbox}")
    if not options.dry_run:
        xclbin = options.fpga_bin_dir / "vortex_afu.xclbin"
        if not xclbin.exists():
            raise FileNotFoundError(f"vortex_afu.xclbin not found under FPGA bin dir: {options.fpga_bin_dir}")
    if options.retry:
        if not options.blackbox_timeout:
            raise ValueError("--retry requires --blackbox-timeout or defaults.blackbox_timeout")
        _parse_timeout_seconds(options.blackbox_timeout)
        if options.retry_max_rounds < 1:
            raise ValueError("--retry-max-rounds must be >= 1")
        if options.retry_timeout_growth <= 1.0:
            raise ValueError("--retry-timeout-growth must be > 1.0")
        if not shlex.split(options.retry_reset_cmd):
            raise ValueError("--retry-reset-cmd must not be empty")


def build_execution_units(suite: BenchSuite, out_dir: Path) -> list[ExecutionUnit]:
    units: dict[str, ExecutionUnit] = {}
    for case in suite.cases:
        if case.exec_key in units:
            continue
        units[case.exec_key] = ExecutionUnit(
            exec_key=case.exec_key,
            app=case.app,
            args=case.args,
            warmup=case.warmup,
            iterations=case.iterations,
            raw_csv=out_dir / "raw" / f"{case.exec_key}.csv",
            log_file=out_dir / "logs" / f"{case.exec_key}.log",
        )
    return list(units.values())


def _normalize_args(value: str) -> str:
    return " ".join(str(value).split())


def _parse_int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _current_xclbin_sha(fpga_bin_dir: Path) -> str:
    xclbin = fpga_bin_dir / "vortex_afu.xclbin"
    return sha256_file(xclbin) if xclbin.exists() else ""


def find_existing_pass_exec_keys(
    raw_db: Path,
    units: list[ExecutionUnit],
    *,
    fpga_bin_label: str,
    xclbin_sha256: str,
) -> tuple[str, ...]:
    if not raw_db.exists() or not xclbin_sha256:
        return ()

    units_by_key = {unit.exec_key: unit for unit in units}
    matched: set[str] = set()
    with raw_db.open(newline="") as fp:
        for row in csv.DictReader(fp):
            if row.get("status") != "pass":
                continue
            if row.get("fpga_bin_label") != fpga_bin_label:
                continue
            if row.get("xclbin_sha256") != xclbin_sha256:
                continue
            unit = units_by_key.get(row.get("exec_key", ""))
            if unit is None:
                continue
            if row.get("app") != unit.app:
                continue
            if _normalize_args(row.get("args", "")) != _normalize_args(unit.args):
                continue
            if _parse_int(row.get("warmup")) != unit.warmup:
                continue
            if _parse_int(row.get("iterations")) != unit.iterations:
                continue
            matched.add(unit.exec_key)

    return tuple(unit.exec_key for unit in units if unit.exec_key in matched)


def _q(value: str | Path) -> str:
    return shlex.quote(str(value))


def _bash_array(values: tuple[str, ...] | list[str]) -> str:
    return "(" + " ".join(_q(value) for value in values) + ")"


_TIMEOUT_RE = re.compile(r"^\s*(?P<value>(?:\d+(?:\.\d*)?|\.\d+))\s*(?P<unit>[smhdSMHD]?)\s*$")
_TIMEOUT_UNIT_SECONDS = {
    "": 1,
    "s": 1,
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
}


def _parse_timeout_seconds(value: str) -> int:
    match = _TIMEOUT_RE.match(value)
    if not match:
        raise ValueError(f"unsupported timeout duration for retry: {value!r}")
    seconds = float(match.group("value")) * _TIMEOUT_UNIT_SECONDS[match.group("unit").lower()]
    if seconds <= 0:
        raise ValueError(f"timeout duration must be positive for retry: {value!r}")
    return max(1, math.ceil(seconds))


def _safe_filename(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def _git_output(args: list[str], cwd: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(cwd), *args],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        return ""


def collect_git_metadata(cwd: Path | None = None) -> GitMetadata:
    root = cwd or repo_root()
    commit = _git_output(["rev-parse", "--short=12", "HEAD"], root)
    branch = _git_output(["rev-parse", "--abbrev-ref", "HEAD"], root)
    if branch == "HEAD":
        branch = "DETACHED"
    status = _git_output(["status", "--porcelain"], root)
    dirty = "1" if status else "0"
    if not commit:
        dirty = ""
    return GitMetadata(commit=commit, branch=branch, dirty=dirty)


def write_cases_csv(suite: BenchSuite, out_dir: Path) -> None:
    rows = suite_to_rows(suite)
    with (out_dir / "cases.csv").open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def write_suite_snapshots(suite: BenchSuite, out_dir: Path) -> None:
    if suite.source_path:
        shutil.copy2(suite.source_path, out_dir / "suite.yaml")
    expanded = suite_to_expanded_yaml(suite)
    with (out_dir / "suite.expanded.yaml").open("w") as fp:
        yaml.safe_dump(expanded, fp, sort_keys=False)


def write_run_script(suite: BenchSuite, options: RunOptions, units: list[ExecutionUnit]) -> Path:
    script = options.out_dir / "run_fpga_bench.sh"
    status_csv = options.out_dir / "run_status.csv"
    progress_csv = options.out_dir / "progress.csv"
    attempt_status_csv = options.out_dir / "attempt_status.csv"
    append_raw_csv = options.append_raw_csv.resolve() if options.append_raw_csv else None
    retry_enabled = 1 if options.retry else 0
    retry_initial_timeout_s = _parse_timeout_seconds(options.blackbox_timeout) if options.retry else 0
    retry_max_rounds = options.retry_max_rounds if options.retry else 1
    retry_reset_cmd = tuple(shlex.split(options.retry_reset_cmd))
    status_columns = (
        "exec_key",
        "app",
        "returncode",
        "failure_phase",
        "failure_reason",
        "raw_csv",
        "log_file",
        "elapsed_wall_s",
    )
    attempt_status_columns = (
        "retry_round",
        "exec_key",
        "app",
        "returncode",
        "failure_phase",
        "failure_reason",
        "blackbox_timeout",
        "reset_ran",
        "reset_rc",
        "raw_csv",
        "log_file",
        "elapsed_wall_s",
    )
    lines = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        f"cd {_q(options.build_dir)}",
        f"mkdir -p {_q(options.out_dir / 'raw')} {_q(options.out_dir / 'logs')}",
        f"printf '%s\\n' {_q(','.join(status_columns))} > {_q(status_csv)}",
        f"printf '%s\\n' {_q(','.join(attempt_status_columns))} > {_q(attempt_status_csv)}",
        f"printf '%s\\n' {_q(','.join(PROGRESS_COLUMNS))} > {_q(progress_csv)}",
        f"export FPGA_BIN_DIR={_q(options.fpga_bin_dir)}",
        f"export TARGET={_q('hw')}",
        f"export PLATFORM={_q(options.platform)}",
        f"export DRIVER={_q('xrt')}",
        f"export XRT_DEVICE_INDEX={_q(str(options.xrt_device_index))}",
        f"export PYTHONPATH={_q(repo_root())}:\"${{PYTHONPATH:-}}\"",
        f"export LATENCY_BENCH_RUN_ID={_q(options.run_id or default_run_id())}",
        f"LATENCY_BENCH_RETRY_ENABLED={retry_enabled}",
        f"LATENCY_BENCH_RETRY_MAX_ROUNDS={retry_max_rounds}",
        f"LATENCY_BENCH_RETRY_TIMEOUT_GROWTH={_q(str(options.retry_timeout_growth))}",
        f"LATENCY_BENCH_CURRENT_TIMEOUT_S={retry_initial_timeout_s}",
        f"LATENCY_BENCH_RETRY_RESET_WAIT={_q(options.retry_reset_wait)}",
        f"LATENCY_BENCH_RESET_SRUN_ARGS={_bash_array(tuple(options.srun_args))}",
        f"LATENCY_BENCH_RESET_CMD={_bash_array(retry_reset_cmd)}",
        "LATENCY_BENCH_LAST_RESET_RC=",
        "",
        "latency_bench_retry_delay_s() {",
        "  case \"$1\" in",
        "    1) printf '5\\n' ;;",
        "    *) printf '15\\n' ;;",
        "  esac",
        "}",
        "",
        "latency_bench_cleanup_timeout() {",
        "  local raw_csv=\"$1\"",
        "  local log_file=\"$2\"",
        "  local pids parents pid ppid live",
        "  pids=$(pgrep -f -- \"$raw_csv\" 2>/dev/null || true)",
        "  if [[ -z \"$pids\" ]]; then return 0; fi",
        "  printf '[latency-bench] timeout cleanup for %s: pids=%s\\n' \"$raw_csv\" \"$pids\" >> \"$log_file\"",
        "  parents=\"\"",
        "  for pid in $pids; do",
        "    ppid=$(ps -o ppid= -p \"$pid\" 2>/dev/null | tr -d ' ' || true)",
        "    if [[ -n \"$ppid\" && \"$ppid\" != \"1\" && \"$ppid\" != \"$$\" ]]; then parents=\"$parents $ppid\"; fi",
        "  done",
        "  kill $pids 2>/dev/null || true",
        "  sleep 2",
        "  live=\"\"",
        "  for pid in $pids $parents; do",
        "    if [[ -n \"$pid\" ]] && kill -0 \"$pid\" 2>/dev/null; then live=\"$live $pid\"; fi",
        "  done",
        "  if [[ -n \"$live\" ]]; then",
        "    printf '[latency-bench] timeout cleanup kill -9:%s\\n' \"$live\" >> \"$log_file\"",
        "    kill -9 $live 2>/dev/null || true",
        "  fi",
        "}",
        "",
        "latency_bench_grow_timeout_s() {",
        "  \"${PYTHON:-python3}\" - \"$1\" \"$2\" <<'PY'",
        "import math",
        "import sys",
        "current = int(sys.argv[1])",
        "growth = float(sys.argv[2])",
        "print(max(current + 1, math.ceil(current * growth)))",
        "PY",
        "}",
        "",
        "latency_bench_reset_fpga() {",
        "  local log_file=\"$1\"",
        "  local reset_rc",
        "  LATENCY_BENCH_LAST_RESET_RC=",
        "  set +e",
        "  if [[ -n \"${SLURM_JOB_ID:-}\" ]]; then",
        "    printf '[latency-bench] timeout reset: direct %s\\n' \"${LATENCY_BENCH_RESET_CMD[*]}\" >> \"$log_file\"",
        "    printf 'y\\n' | timeout --kill-after=10s 60s \"${LATENCY_BENCH_RESET_CMD[@]}\" >> \"$log_file\" 2>&1",
        "  else",
        "    printf '[latency-bench] timeout reset: srun %s\\n' \"${LATENCY_BENCH_RESET_CMD[*]}\" >> \"$log_file\"",
        "    printf 'y\\n' | timeout --kill-after=10s 60s srun \"${LATENCY_BENCH_RESET_SRUN_ARGS[@]}\" \"${LATENCY_BENCH_RESET_CMD[@]}\" >> \"$log_file\" 2>&1",
        "  fi",
        "  reset_rc=$?",
        "  set -u",
        "  LATENCY_BENCH_LAST_RESET_RC=\"$reset_rc\"",
        "  printf '[latency-bench] timeout reset rc=%s\\n' \"$reset_rc\" >> \"$log_file\"",
        "  if [[ -n \"$LATENCY_BENCH_RETRY_RESET_WAIT\" && \"$LATENCY_BENCH_RETRY_RESET_WAIT\" != \"0\" ]]; then",
        "    sleep \"$LATENCY_BENCH_RETRY_RESET_WAIT\"",
        "  fi",
        "  return \"$reset_rc\"",
        "}",
        "",
        "latency_bench_failure_reason() {",
        "  local rc=\"$1\"",
        "  local failure_phase=\"$2\"",
        "  local attempt_log=\"$3\"",
        "  if [[ \"$failure_phase\" == \"build\" ]]; then printf 'build\\n'; return 0; fi",
        "  if [[ \"$rc\" == \"124\" || \"$rc\" == \"137\" ]]; then printf 'timeout\\n'; return 0; fi",
        "  if [[ \"$rc\" != \"0\" && -f \"$attempt_log\" ]] && grep -q 'failed to open cu context' \"$attempt_log\"; then",
        "    printf 'xrt_context_open\\n'",
        "    return 0",
        "  fi",
        "  if [[ \"$rc\" != \"0\" ]]; then printf 'run\\n'; return 0; fi",
        "  printf '\\n'",
        "}",
    ]
    if options.configs:
        lines.extend([
            f"if [[ ! -f {_q(options.configs)} ]]; then",
            f"  echo 'config file not found: {_q(options.configs)}' >&2",
            "  exit 1",
            "fi",
            f"source {_q(options.configs)}",
        ])
    if options.configs_extra:
        lines.append(f"export CONFIGS=\"${{CONFIGS:-}} {options.configs_extra}\"")

    blackbox_args = " ".join(_q(arg) for arg in options.blackbox_args)
    blackbox_args = f"{blackbox_args} " if blackbox_args else ""
    lines.extend([
        "declare -A LATENCY_BENCH_BUILD_RC",
        "declare -A LATENCY_BENCH_BUILD_LOG",
    ])
    if options.prebuild:
        apps = list(dict.fromkeys(unit.app for unit in units))
        for idx, app in enumerate(apps, start=1):
            build_log = options.out_dir / "logs" / f"build_{_safe_filename(app)}.log"
            build_cmd = (
                f"./ci/blackbox.sh {blackbox_args}--driver=xrt --bench --build-only "
                f"--app={_q(app)}"
            )
            lines.extend([
                "",
                f"echo '[build {idx}/{len(apps)}] app={app}'",
                f"LATENCY_BENCH_BUILD_LOG[{_q(app)}]={_q(build_log)}",
                "set +e",
                f"{build_cmd} > {_q(build_log)} 2>&1",
                "rc=$?",
                "set -u",
                f"LATENCY_BENCH_BUILD_RC[{_q(app)}]=\"$rc\"",
            ])

    lines.extend([
        "",
        "declare -A LATENCY_BENCH_SHOULD_RUN",
        "declare -A LATENCY_BENCH_NEXT_SHOULD_RUN",
        "LATENCY_BENCH_EXEC_KEYS=()",
    ])
    for unit in units:
        lines.extend([
            f"LATENCY_BENCH_EXEC_KEYS+=({_q(unit.exec_key)})",
            f"LATENCY_BENCH_SHOULD_RUN[{_q(unit.exec_key)}]=1",
        ])
    lines.extend([
        "LATENCY_BENCH_RETRY_ROUND=1",
        "while true; do",
        "LATENCY_BENCH_TIMEOUT_FAILURES=0",
        "for exec_key in \"${LATENCY_BENCH_EXEC_KEYS[@]}\"; do LATENCY_BENCH_NEXT_SHOULD_RUN[\"$exec_key\"]=0; done",
        "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" == \"1\" ]]; then",
        "  echo \"[latency-bench] retry round ${LATENCY_BENCH_RETRY_ROUND}/${LATENCY_BENCH_RETRY_MAX_ROUNDS}, timeout=${LATENCY_BENCH_CURRENT_TIMEOUT_S}s\"",
        "fi",
    ])

    for idx, unit in enumerate(units, start=1):
        bench_args = f"--warmup={unit.warmup} --iterations={unit.iterations} --csv --output={unit.raw_csv} {unit.args}"
        run_only_arg = "--run-only " if options.prebuild else ""
        blackbox_cmd = (
            f"./ci/blackbox.sh {blackbox_args}--driver=xrt --bench {run_only_arg}"
            f"--app={_q(unit.app)} --args={_q(bench_args)} --log={_q(unit.log_file.with_suffix(unit.log_file.suffix + '.blackbox'))}"
        )
        if options.retry:
            blackbox_cmd = f'timeout --kill-after=30s "${{LATENCY_BENCH_CURRENT_TIMEOUT_S}}s" {blackbox_cmd}'
        elif options.blackbox_timeout:
            blackbox_cmd = f"timeout --kill-after=30s {_q(options.blackbox_timeout)} {blackbox_cmd}"
        lines.extend([
            "",
            f"if [[ \"${{LATENCY_BENCH_SHOULD_RUN[{_q(unit.exec_key)}]:-0}}\" == \"1\" ]]; then",
            f"echo '[{idx}/{len(units)}] {unit.exec_key} app={unit.app} args={bench_args}'",
            f"build_rc=\"${{LATENCY_BENCH_BUILD_RC[{_q(unit.app)}]:-0}}\"",
            f"build_log=\"${{LATENCY_BENCH_BUILD_LOG[{_q(unit.app)}]:-}}\"",
            "failure_phase=\"\"",
            "failure_reason=\"\"",
            "final_attempt_log=\"\"",
            "blackbox_timeout_label=\"\"",
            "reset_ran=\"0\"",
            "reset_rc=\"\"",
            "if [[ \"$LATENCY_BENCH_CURRENT_TIMEOUT_S\" != \"0\" ]]; then blackbox_timeout_label=\"${LATENCY_BENCH_CURRENT_TIMEOUT_S}s\"; fi",
            "if [[ \"$build_rc\" != \"0\" ]]; then",
            "  rc=\"$build_rc\"",
            "  failure_phase=\"build\"",
            "  failure_reason=\"build\"",
            "  elapsed_wall_s=\"0.000\"",
            f"  if [[ -n \"$build_log\" && -f \"$build_log\" ]]; then cp \"$build_log\" {_q(unit.log_file)}; fi",
            f"  if [[ ! -f {_q(unit.log_file)} ]]; then printf 'build failed before log was written\\n' > {_q(unit.log_file)}; fi",
            f"  final_attempt_log={_q(unit.log_file)}",
            "else",
            "  set +e",
            "  start_ns=$(date +%s%N)",
            "  attempt=1",
            "  max_attempts=3",
            "  while true; do",
            f"    attempt_log={_q(str(unit.log_file) + '.attempt')}${{attempt}}",
            "    final_attempt_log=\"$attempt_log\"",
            f"    {blackbox_cmd} > \"$attempt_log\" 2>&1",
            "    rc=$?",
            f"    if [[ \"$attempt\" == \"1\" && \"$LATENCY_BENCH_RETRY_ROUND\" == \"1\" ]]; then cp \"$attempt_log\" {_q(unit.log_file)}; else printf '\\n[latency-bench] retry round %d attempt %d/%d log follows\\n' \"$LATENCY_BENCH_RETRY_ROUND\" \"$attempt\" \"$max_attempts\" >> {_q(unit.log_file)}; cat \"$attempt_log\" >> {_q(unit.log_file)}; fi",
            f"    if [[ \"$rc\" == \"124\" || \"$rc\" == \"137\" ]]; then latency_bench_cleanup_timeout {_q(unit.raw_csv)} {_q(unit.log_file)}; fi",
            "    if [[ \"$rc\" != \"0\" && -f \"$attempt_log\" ]] && grep -q 'failed to open cu context' \"$attempt_log\" && [[ \"$attempt\" -lt \"$max_attempts\" ]]; then",
            "      delay_s=$(latency_bench_retry_delay_s \"$attempt\")",
            f"      printf '[latency-bench] xrt_context_open retry %d/%d after %ss\\n' \"$attempt\" \"$max_attempts\" \"$delay_s\" >> {_q(unit.log_file)}",
            "      sleep \"$delay_s\"",
            "      attempt=$((attempt + 1))",
            "      continue",
            "    fi",
            "    break",
            "  done",
            "  end_ns=$(date +%s%N)",
            "  elapsed_ms=$(( (end_ns - start_ns + 500000) / 1000000 ))",
            "  printf -v elapsed_wall_s '%d.%03d' $((elapsed_ms / 1000)) $((elapsed_ms % 1000))",
            "  set -u",
            "  if [[ \"$rc\" != \"0\" ]]; then failure_phase=\"run\"; fi",
            "  failure_reason=$(latency_bench_failure_reason \"$rc\" \"$failure_phase\" \"$final_attempt_log\")",
            "fi",
            "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" == \"1\" && \"$failure_reason\" == \"timeout\" ]]; then",
            f"  if latency_bench_reset_fpga {_q(unit.log_file)}; then :; else :; fi",
            "  reset_ran=\"1\"",
            "  reset_rc=\"$LATENCY_BENCH_LAST_RESET_RC\"",
            "fi",
            (
                f"printf '%s,%s,%s,%s,%s,%s,%s,%s\\n' "
                f"{_q(unit.exec_key)} {_q(unit.app)} \"$rc\" \"$failure_phase\" \"$failure_reason\" {_q(unit.raw_csv)} {_q(unit.log_file)} \"$elapsed_wall_s\" "
                f">> {_q(status_csv)}"
            ),
            (
                f"printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\\n' "
                f"\"$LATENCY_BENCH_RETRY_ROUND\" {_q(unit.exec_key)} {_q(unit.app)} \"$rc\" \"$failure_phase\" \"$failure_reason\" \"$blackbox_timeout_label\" "
                f"\"$reset_ran\" \"$reset_rc\" {_q(unit.raw_csv)} {_q(unit.log_file)} \"$elapsed_wall_s\" "
                f">> {_q(attempt_status_csv)}"
            ),
            (
                f"\"${{PYTHON:-python3}}\" -m tools.latency_bench.progress "
                f"--output {_q(progress_csv)} "
                f"--idx {idx} "
                f"--total {len(units)} "
                f"--run-id \"$LATENCY_BENCH_RUN_ID\" "
                f"--suite {_q(suite.name)} "
                f"--exec-key {_q(unit.exec_key)} "
                f"--app {_q(unit.app)} "
                f"--args {_q(unit.args)} "
                f"--warmup {unit.warmup} "
                f"--iterations {unit.iterations} "
                f"--returncode \"$rc\" "
                f"--failure-phase \"$failure_phase\" "
                f"--failure-reason \"$failure_reason\" "
                f"--elapsed-wall-s \"$elapsed_wall_s\" "
                f"--raw-csv {_q(unit.raw_csv)} "
                f"--log-file {_q(unit.log_file)}"
            ),
        ])
        if append_raw_csv:
            lines.extend([
                (
                    f"\"${{PYTHON:-python3}}\" -m tools.latency_bench.append_raw "
                    f"--output {_q(append_raw_csv)} "
                    f"--suite {_q(suite.name)} "
                    f"--run-id \"$LATENCY_BENCH_RUN_ID\" "
                    f"--exec-key {_q(unit.exec_key)} "
                    f"--app {_q(unit.app)} "
                    f"--returncode \"$rc\" "
                    f"--failure-phase \"$failure_phase\" "
                    f"--failure-reason \"$failure_reason\" "
                    f"--raw-csv {_q(unit.raw_csv)} "
                    f"--log-file {_q(unit.log_file)}"
                ),
            ])
        lines.extend([
            "if [[ \"$failure_reason\" == \"timeout\" ]]; then",
            "  LATENCY_BENCH_TIMEOUT_FAILURES=$((LATENCY_BENCH_TIMEOUT_FAILURES + 1))",
            f"  LATENCY_BENCH_NEXT_SHOULD_RUN[{_q(unit.exec_key)}]=1",
            "fi",
            "fi",
        ])
    lines.extend([
        "",
        "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" != \"1\" ]]; then break; fi",
        "if [[ \"$LATENCY_BENCH_TIMEOUT_FAILURES\" == \"0\" ]]; then break; fi",
        "if [[ \"$LATENCY_BENCH_RETRY_ROUND\" -ge \"$LATENCY_BENCH_RETRY_MAX_ROUNDS\" ]]; then",
        "  echo \"[latency-bench] retry exhausted with ${LATENCY_BENCH_TIMEOUT_FAILURES} timeout failure(s)\"",
        "  break",
        "fi",
        "for exec_key in \"${LATENCY_BENCH_EXEC_KEYS[@]}\"; do LATENCY_BENCH_SHOULD_RUN[\"$exec_key\"]=\"${LATENCY_BENCH_NEXT_SHOULD_RUN[$exec_key]:-0}\"; done",
        "LATENCY_BENCH_CURRENT_TIMEOUT_S=$(latency_bench_grow_timeout_s \"$LATENCY_BENCH_CURRENT_TIMEOUT_S\" \"$LATENCY_BENCH_RETRY_TIMEOUT_GROWTH\")",
        "LATENCY_BENCH_RETRY_ROUND=$((LATENCY_BENCH_RETRY_ROUND + 1))",
        "done",
    ])
    lines.append("exit 0")
    script.write_text("\n".join(lines) + "\n")
    script.chmod(0o755)
    return script


RAW_DB_COLUMNS = [
    "run_id",
    "timestamp_utc",
    "fpga_bin_label",
    "git_commit",
    "git_branch",
    "git_dirty",
    "suite",
    "case_id",
    "exec_key",
    "app",
    "kind",
    "op",
    "backend",
    "variant",
    "stage",
    "name",
    "args",
    "shape_json",
    "calls_per_forward",
    "fpga_bin_dir",
    "xclbin_sha256",
    "warmup",
    "iterations",
    "source",
    "status",
    "returncode",
    "failure_phase",
    "failure_reason",
    "raw_csv",
    "log_file",
    "elapsed_wall_s",
    "samples",
    "min_us",
    "avg_us",
    "max_us",
    "p50_us",
    "p95_us",
]


def add_git_metadata(results: pd.DataFrame, git: GitMetadata) -> pd.DataFrame:
    rows = results.copy()
    rows.insert(0, "git_dirty", git.dirty)
    rows.insert(0, "git_branch", git.branch)
    rows.insert(0, "git_commit", git.commit)
    return rows


def _raw_db_rows(results: pd.DataFrame, *, run_id: str, fpga_bin_label: str) -> pd.DataFrame:
    rows = results.copy()
    rows.insert(0, "timestamp_utc", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    rows.insert(0, "run_id", run_id)
    rows.insert(2, "fpga_bin_label", fpga_bin_label)
    return rows.reindex(columns=RAW_DB_COLUMNS)


def _ensure_raw_db_schema(raw_db: Path) -> None:
    if not raw_db.exists() or raw_db.stat().st_size == 0:
        return

    with raw_db.open(newline="") as fp:
        reader = csv.reader(fp)
        header = next(reader, [])
    if header == RAW_DB_COLUMNS:
        return

    with raw_db.open(newline="") as fp:
        existing_rows = list(csv.DictReader(fp))

    tmp = raw_db.with_suffix(raw_db.suffix + ".tmp")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        for row in existing_rows:
            writer.writerow({column: _clean_raw_value(row.get(column, "")) for column in RAW_DB_COLUMNS})
    tmp.replace(raw_db)


def append_raw_db(results: pd.DataFrame, out_root: Path, *, run_id: str, fpga_bin_label: str) -> None:
    if results.empty:
        return

    rows = _raw_db_rows(results, run_id=run_id, fpga_bin_label=fpga_bin_label)

    raw_db = out_root / "raw_db.csv"
    raw_db.parent.mkdir(parents=True, exist_ok=True)
    _ensure_raw_db_schema(raw_db)
    write_header = not raw_db.exists() or raw_db.stat().st_size == 0
    rows.to_csv(raw_db, mode="a", header=write_header, index=False)


def _clean_raw_value(value: object) -> str:
    if pd.isna(value):
        return ""
    return str(value)


def _measurement_key(
    *,
    fpga_bin_label: object,
    xclbin_sha256: object,
    exec_key: object,
    app: object,
    args: object,
    warmup: object,
    iterations: object,
) -> tuple[str, str, str, str, str, int | None, int | None]:
    return (
        _clean_raw_value(fpga_bin_label),
        _clean_raw_value(xclbin_sha256),
        _clean_raw_value(exec_key),
        _clean_raw_value(app),
        _normalize_args(_clean_raw_value(args)),
        _parse_int(warmup),
        _parse_int(iterations),
    )


def _measurement_key_from_row(row: dict[str, object]) -> tuple[str, str, str, str, str, int | None, int | None]:
    return _measurement_key(
        fpga_bin_label=row.get("fpga_bin_label", ""),
        xclbin_sha256=row.get("xclbin_sha256", ""),
        exec_key=row.get("exec_key", ""),
        app=row.get("app", ""),
        args=row.get("args", ""),
        warmup=row.get("warmup", ""),
        iterations=row.get("iterations", ""),
    )


def replace_raw_db_rows(results: pd.DataFrame, out_root: Path, *, run_id: str, fpga_bin_label: str) -> int:
    if results.empty:
        return 0

    raw_db = out_root / "raw_db.csv"
    new_rows = _raw_db_rows(results, run_id=run_id, fpga_bin_label=fpga_bin_label)
    replacement_keys = {
        _measurement_key_from_row(row)
        for row in new_rows.to_dict("records")
    }

    existing_rows: list[dict[str, str]] = []
    if raw_db.exists() and raw_db.stat().st_size > 0:
        with raw_db.open(newline="") as fp:
            existing_rows = list(csv.DictReader(fp))

    replaced_count = 0
    kept_rows: list[dict[str, object]] = []
    for row in existing_rows:
        if _measurement_key_from_row(row) in replacement_keys:
            replaced_count += 1
        else:
            kept_rows.append(row)

    output_rows = kept_rows + new_rows.to_dict("records")
    raw_db.parent.mkdir(parents=True, exist_ok=True)
    tmp = raw_db.with_suffix(raw_db.suffix + ".tmp")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        for row in output_rows:
            writer.writerow({column: _clean_raw_value(row.get(column, "")) for column in RAW_DB_COLUMNS})
    tmp.replace(raw_db)
    return replaced_count


def run_suite(suite: BenchSuite, options: RunOptions) -> int:
    git = collect_git_metadata()
    out_root = options.out_dir
    run_id = options.run_id or os.environ.get("LATENCY_BENCH_RUN_ID") or default_run_id()
    run_dir = out_root / "runs" / run_id
    run_options = replace(options, out_dir=run_dir, run_id=run_id)

    out_root.mkdir(parents=True, exist_ok=True)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "raw").mkdir(exist_ok=True)
    (run_dir / "logs").mkdir(exist_ok=True)

    validate_inputs(run_options)
    units = build_execution_units(suite, run_dir)
    skipped_existing_exec_keys: tuple[str, ...] = ()
    units_to_run = units
    if options.skip_existing:
        skipped_existing_exec_keys = find_existing_pass_exec_keys(
            out_root / "raw_db.csv",
            units,
            fpga_bin_label=run_options.fpga_bin_label,
            xclbin_sha256=_current_xclbin_sha(run_options.fpga_bin_dir),
        )
        skipped = set(skipped_existing_exec_keys)
        units_to_run = [unit for unit in units if unit.exec_key not in skipped]
    write_cases_csv(suite, run_dir)
    write_suite_snapshots(suite, run_dir)
    script = write_run_script(suite, run_options, units_to_run)
    write_manifest(suite, run_dir, {
        "run_id": run_id,
        "out_root": str(out_root),
        "run_dir": str(run_dir),
        "raw_db": str(out_root / "raw_db.csv"),
        "progress_csv": str(run_dir / "progress.csv"),
        "attempt_status_csv": str(run_dir / "attempt_status.csv"),
        "build_dir": str(run_options.build_dir),
        "fpga_bin_label": run_options.fpga_bin_label,
        "fpga_bin_dir": str(run_options.fpga_bin_dir),
        "git_commit": git.commit,
        "git_branch": git.branch,
        "git_dirty": git.dirty,
        "platform": options.platform,
        "xrt_device_index": options.xrt_device_index,
        "blackbox_args": list(options.blackbox_args),
        "blackbox_timeout": options.blackbox_timeout,
        "configs": str(options.configs) if options.configs else "",
        "configs_extra": options.configs_extra,
        "execution_count": len(units),
        "run_execution_count": len(units_to_run),
        "skip_existing": options.skip_existing,
        "prebuild": options.prebuild,
        "case_filters": list(options.case_filters),
        "retry": options.retry,
        "retry_max_rounds": options.retry_max_rounds,
        "retry_timeout_growth": options.retry_timeout_growth,
        "retry_reset_wait": options.retry_reset_wait,
        "retry_reset_cmd": options.retry_reset_cmd,
        "retry_reset_srun_args": list(options.srun_args),
        "skipped_existing_count": len(skipped_existing_exec_keys),
        "skipped_existing_exec_keys": list(skipped_existing_exec_keys),
        "script": str(script),
        "dry_run": options.dry_run,
        "append_raw_csv": str(options.append_raw_csv) if options.append_raw_csv else "",
    })

    if options.dry_run:
        print(f"dry-run: wrote {script}")
        print(f"dry-run: expanded {len(suite.cases)} cases into {len(units)} unique executions")
        if options.skip_existing:
            print(f"dry-run: skipped {len(skipped_existing_exec_keys)} existing pass executions")
        return 0

    cmd = ["bash", str(script)]
    if options.srun:
        cmd = ["srun", *options.srun_args, "bash", str(script)]
    print("+ " + " ".join(shlex.quote(part) for part in cmd), flush=True)
    rc = subprocess.call(cmd, env=os.environ.copy())

    results = build_results(suite, run_dir, options.fpga_bin_dir)
    results = add_git_metadata(results, git)
    summary = build_summary(results)
    results.to_csv(run_dir / "results.csv", index=False)
    summary.to_csv(run_dir / "summary.csv", index=False)
    append_results = results
    if options.skip_existing:
        executed_keys = {unit.exec_key for unit in units_to_run}
        append_results = results[results["exec_key"].isin(executed_keys)]
        replaced_count = replace_raw_db_rows(append_results, out_root, run_id=run_id, fpga_bin_label=options.fpga_bin_label)
    else:
        replaced_count = 0
        append_raw_db(append_results, out_root, run_id=run_id, fpga_bin_label=options.fpga_bin_label)
    print(f"wrote {run_dir / 'results.csv'}")
    print(f"wrote {run_dir / 'summary.csv'}")
    if append_results.empty:
        print(f"no new rows appended to {out_root / 'raw_db.csv'}")
    elif options.skip_existing:
        print(f"replaced {replaced_count} existing rows and wrote {len(append_results)} rows to {out_root / 'raw_db.csv'}")
    else:
        print(f"appended {out_root / 'raw_db.csv'}")
    return rc
