from __future__ import annotations

import csv
import json
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
from .interpolation import write_current_cases
from .progress import PROGRESS_COLUMNS
from .raw_db import (
    RAW_DB_COLUMNS,
    _normalize_args,
    _parse_bool_cell,
    _parse_int,
    _write_raw_rows,
)
from .report import build_results, build_summary, sha256_file, write_manifest
from .status import DEFAULT_POWER_MIN_SAMPLES, power_samples_below_threshold
from .suite import BenchCase, BenchSuite, suite_to_expanded_yaml, suite_to_rows


DEFAULT_SRUN_ARGS = (
    "--gres=fpga:u55c:1",
    "--cpus-per-task=4",
    "--mem=16G",
    "--time=7-00:00:00",
    # "--time=14-00:00:00",
    # "--time=12:00:00",
)
DEFAULT_RETRY_MAX_ROUNDS = 5
DEFAULT_RETRY_TIMEOUT_GROWTH = 1.10
DEFAULT_RETRY_RESET_WAIT = "10s"
DEFAULT_RETRY_RESET_CMD = "xrt-smi reset"
DEFAULT_POWER_MAX_ITERATIONS = 1024
DEFAULT_SKIP_EXISTING_COLUMNS = ("status", "xclbin_sha256", "app", "args")
SUPPORTED_SKIP_EXISTING_COLUMNS = frozenset((
    "status",
    "fpga_bin_label",
    "xclbin_sha256",
    "measure_latency",
    "measure_power",
    "power_samples",
    "exec_key",
    "app",
    "args",
    "padded_args",
    "warmup",
    "iterations",
))
CASE_COLUMNS = [
    "suite",
    "case_id",
    "exec_key",
    "app",
    "model",
    "kind",
    "op",
    "backend",
    "variant",
    "stage",
    "name",
    "batch",
    "prefill_seq_len",
    "gen_kv_len",
    "args",
    "measurement_args",
    "latency_shape_json",
    "padded_args",
    "shape_json",
    "calls_per_forward",
    "output_token_index",
    "out_tokens",
    "measurement_kind",
    "warmup",
    "iterations",
    "source",
]


@dataclass(frozen=True)
class ExecutionUnit:
    exec_key: str
    app: str
    args: str
    warmup: int
    iterations: int
    raw_csv: Path
    power_csv: Path
    power_summary: Path
    log_file: Path


@dataclass(frozen=True)
class RunOptions:
    build_dir: Path
    fpga_bin_dir: Path
    out_dir: Path
    platform: str
    xrt_device_index: int | None = None
    xrt_device_bdf: str = ""
    fpga_bin_label: str = ""
    configs: Path | None = None
    configs_extra: str = ""
    blackbox_args: tuple[str, ...] = ()
    blackbox_timeout: str = ""
    srun: bool = True
    srun_args: tuple[str, ...] = DEFAULT_SRUN_ARGS
    dry_run: bool = False
    append_raw_csv: Path | None = None
    run_id: str | None = None
    skip_existing: bool = False
    skip_existing_columns: tuple[str, ...] = DEFAULT_SKIP_EXISTING_COLUMNS
    prebuild: bool = True
    program_fpga: bool = True
    measure_latency: bool = True
    measure_power: bool = True
    power_measure_latency: bool = False
    power_auto_duration: bool = True
    power_min_run_sec: float = 10.0
    power_max_run_sec: float = 60.0
    power_max_iterations: int = DEFAULT_POWER_MAX_ITERATIONS
    power_target_samples: int = 100
    power_latency_interval: float = 1.0
    power_min_interval: float = 0.05
    power_max_interval: float = 1.0
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES
    power_kernel_iterations: int = 1
    power_kernel_iterations_auto: bool = False
    power_target_sec: float = 20.0
    power_fpga_freq_mhz: float = 100.0
    power_fpga_freq_mhz_auto: bool = True
    power_xclbin_info: str = ""
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
    normalize_skip_existing_columns(options.skip_existing_columns)
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
    if options.power_min_samples < 0:
        raise ValueError("--power-min-samples must be >= 0")
    if options.power_kernel_iterations < 1:
        raise ValueError("--power-kernel-iterations must be >= 1")
    if options.power_target_sec <= 0:
        raise ValueError("--power-target-sec must be > 0")
    if options.power_fpga_freq_mhz <= 0:
        raise ValueError("--power-fpga-freq-mhz must be > 0")
    if options.measure_power and options.power_target_samples < 1:
        raise ValueError("--power-target-samples must be >= 1")
    if options.measure_power and options.power_latency_interval <= 0:
        raise ValueError("--power-latency-interval must be > 0")
    if options.measure_power and options.power_auto_duration:
        if options.power_min_run_sec < 0:
            raise ValueError("--power-min-run-sec must be >= 0")
        if options.power_max_run_sec <= 0:
            raise ValueError("--power-max-run-sec must be > 0")
        if options.power_max_run_sec < options.power_min_run_sec:
            raise ValueError("--power-max-run-sec must be >= --power-min-run-sec")
        if options.power_max_iterations < 0:
            raise ValueError("--power-max-iterations must be >= 0")
        if options.power_min_interval <= 0:
            raise ValueError("--power-min-interval must be > 0")
        if options.power_max_interval < options.power_min_interval:
            raise ValueError("--power-max-interval must be >= --power-min-interval")


def build_execution_units(suite: BenchSuite, out_dir: Path) -> list[ExecutionUnit]:
    units: dict[str, ExecutionUnit] = {}
    for case in suite.cases:
        if case.measurement_kind != "measured":
            continue
        if case.exec_key in units:
            continue
        units[case.exec_key] = ExecutionUnit(
            exec_key=case.exec_key,
            app=case.app,
            args=case.measurement_args or case.args,
            warmup=case.warmup,
            iterations=case.iterations,
            raw_csv=out_dir / "raw" / f"{case.exec_key}.csv",
            power_csv=out_dir / "power" / f"{case.exec_key}.csv",
            power_summary=out_dir / "power" / f"{case.exec_key}.summary.csv",
            log_file=out_dir / "logs" / f"{case.exec_key}.log",
        )
    return list(units.values())


def _bool_csv(value: bool) -> str:
    return "1" if value else "0"


def _current_xclbin_sha(fpga_bin_dir: Path) -> str:
    xclbin = fpga_bin_dir / "vortex_afu.xclbin"
    return sha256_file(xclbin) if xclbin.exists() else ""


def normalize_skip_existing_columns(columns: object) -> tuple[str, ...]:
    raw_columns: list[str] = []
    if columns is None:
        raw_columns.extend(DEFAULT_SKIP_EXISTING_COLUMNS)
    elif isinstance(columns, str):
        raw_columns.extend(columns.split(","))
    else:
        for value in columns:
            raw_columns.extend(str(value).split(","))

    normalized: list[str] = []
    for column in raw_columns:
        column = column.strip()
        if not column:
            continue
        if column not in SUPPORTED_SKIP_EXISTING_COLUMNS:
            supported = ", ".join(sorted(SUPPORTED_SKIP_EXISTING_COLUMNS))
            raise ValueError(f"unsupported skip-existing column {column!r}; supported columns: {supported}")
        if column not in normalized:
            normalized.append(column)
    if not normalized:
        raise ValueError("--skip-existing-columns must include at least one column")
    return tuple(normalized)


def _skip_existing_column_matches(
    column: str,
    row: dict[str, str],
    unit: ExecutionUnit,
    *,
    fpga_bin_label: str,
    xclbin_sha256: str,
    measure_latency: bool,
    measure_power: bool,
    power_min_samples: int,
) -> bool:
    if column == "status":
        return row.get("status") == "pass"
    if column == "fpga_bin_label":
        return row.get("fpga_bin_label") == fpga_bin_label
    if column == "xclbin_sha256":
        return bool(xclbin_sha256) and row.get("xclbin_sha256") == xclbin_sha256
    if column == "measure_latency":
        return _parse_bool_cell(row.get("measure_latency", ""), default=True) == measure_latency
    if column == "measure_power":
        return _parse_bool_cell(row.get("measure_power", ""), default=False) == measure_power
    if column == "power_samples":
        return not measure_power or not power_samples_below_threshold(row, power_min_samples)
    if column == "exec_key":
        return row.get("exec_key", "") == unit.exec_key
    if column == "app":
        return row.get("app") == unit.app
    if column == "args":
        return _normalize_args(row.get("args", "")) == _normalize_args(unit.args)
    if column == "warmup":
        return _parse_int(row.get("warmup")) == unit.warmup
    if column == "iterations":
        return _parse_int(row.get("iterations")) == unit.iterations
    raise AssertionError(f"unhandled skip-existing column: {column}")


def find_existing_pass_exec_keys(
    raw_db: Path,
    units: list[ExecutionUnit],
    *,
    fpga_bin_label: str,
    xclbin_sha256: str,
    measure_latency: bool,
    measure_power: bool,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
    skip_existing_columns: tuple[str, ...] = DEFAULT_SKIP_EXISTING_COLUMNS,
) -> tuple[str, ...]:
    if not raw_db.exists():
        return ()

    skip_existing_columns = normalize_skip_existing_columns(skip_existing_columns)
    matched: set[str] = set()
    with raw_db.open(newline="") as fp:
        for row in csv.DictReader(fp):
            for unit in units:
                if unit.exec_key in matched:
                    continue
                if all(
                    _skip_existing_column_matches(
                        column,
                        row,
                        unit,
                        fpga_bin_label=fpga_bin_label,
                        xclbin_sha256=xclbin_sha256,
                        measure_latency=measure_latency,
                        measure_power=measure_power,
                        power_min_samples=power_min_samples,
                    )
                    for column in skip_existing_columns
                ):
                    matched.add(unit.exec_key)

    return tuple(unit.exec_key for unit in units if unit.exec_key in matched)


def raw_db_update_mode(options: RunOptions) -> str:
    if options.skip_existing or options.retry:
        return "replace"
    return "replace-run"


def has_slurm_allocation(env: dict[str, str] | os._Environ[str] | None = None) -> bool:
    source = os.environ if env is None else env
    return bool(source.get("SLURM_JOB_ID") or source.get("SLURM_STEP_ID"))


def slurm_run_mode(options: RunOptions, env: dict[str, str] | os._Environ[str] | None = None) -> str:
    if options.srun and has_slurm_allocation(env):
        return "inherited_slurm"
    if options.srun:
        return "managed_srun"
    return "direct_no_srun_compat"


def run_script_command(script: Path, options: RunOptions, env: dict[str, str] | os._Environ[str] | None = None) -> list[str]:
    if slurm_run_mode(options, env) == "managed_srun":
        return ["srun", *options.srun_args, "bash", str(script)]
    return ["bash", str(script)]


def seed_raw_db_cases(
    suite: BenchSuite,
    units: list[ExecutionUnit],
    *,
    raw_db: Path,
    options: RunOptions,
    git: GitMetadata,
    xclbin_sha256: str,
) -> int:
    unit_by_exec_key = {unit.exec_key: unit for unit in units}
    if not unit_by_exec_key:
        return 0

    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    cases_by_exec: dict[str, list[dict[str, object]]] = {}
    for case in suite_to_rows(suite):
        cases_by_exec.setdefault(str(case.get("exec_key", "")), []).append(case)

    rows: list[dict[str, object]] = []
    for exec_key, unit in unit_by_exec_key.items():
        cases = cases_by_exec.get(exec_key, [])
        if not cases:
            continue
        padded_values = {
            _normalize_args(str(case.get("padded_args", "")))
            for case in cases if str(case.get("padded_args", "")).strip()
        }
        if len(padded_values) > 1:
            raise ValueError(
                f"exec_key={exec_key!r} has conflicting padded_args: "
                f"{sorted(padded_values)}"
            )
        row = {column: "" for column in RAW_DB_COLUMNS}
        row.update({
            "exec_key": exec_key,
            "app": unit.app,
            "args": unit.args,
            "padded_args": next(iter(padded_values), ""),
            "run_id": options.run_id or "",
            "timestamp_utc": timestamp,
            "fpga_bin_label": options.fpga_bin_label,
            "git_commit": git.commit,
            "git_branch": git.branch,
            "git_dirty": git.dirty,
            "fpga_bin_dir": str(options.fpga_bin_dir),
            "xclbin_sha256": xclbin_sha256,
            "warmup": unit.warmup,
            "iterations": unit.iterations,
            "raw_csv": str(unit.raw_csv),
            "power_csv": str(unit.power_csv) if options.measure_power else "",
            "power_summary": str(unit.power_summary) if options.measure_power else "",
            "measure_latency": _bool_csv(options.measure_latency),
            "measure_power": _bool_csv(options.measure_power),
            "log_file": str(unit.log_file),
        })
        rows.append(row)

    if not rows:
        return 0
    _write_raw_rows(rows, raw_db, mode=raw_db_update_mode(options), run_id=options.run_id or "")
    return len(rows)


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
        writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()) if rows else CASE_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def write_suite_snapshots(suite: BenchSuite, out_dir: Path) -> None:
    if suite.source_path:
        shutil.copy2(suite.source_path, out_dir / "suite.yaml")
    expanded = suite_to_expanded_yaml(suite)
    with (out_dir / "suite.expanded.yaml").open("w") as fp:
        yaml.safe_dump(expanded, fp, sort_keys=False)


def _atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    shutil.copy2(source, temporary)
    temporary.replace(destination)


def publish_run_latest(
    run_dir: Path,
    out_root: Path,
    filenames: tuple[str, ...],
    *,
    run_id: str,
    status: str,
) -> None:
    latest = out_root / "latest"
    latest.mkdir(parents=True, exist_ok=True)
    for filename in filenames:
        source = run_dir / filename
        if source.exists():
            _atomic_copy(source, latest / filename)
    state_path = latest / "run_state.json"
    temporary = state_path.with_name(f".{state_path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps({
        "run_id": run_id,
        "run_dir": str(run_dir.resolve()),
        "status": status,
        "updated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }, indent=2) + "\n")
    temporary.replace(state_path)


def publish_current_cases(
    suite: BenchSuite,
    run_dir: Path,
    out_root: Path,
) -> None:
    current_cases = run_dir / "cases.current.csv"
    write_current_cases(suite, out_root / "raw_db.csv", current_cases)
    _atomic_copy(current_cases, out_root / "latest" / "cases.csv")


def write_run_script(
    suite: BenchSuite,
    options: RunOptions,
    units: list[ExecutionUnit],
    *,
    raw_db: Path,
    git: GitMetadata,
    xclbin_sha256: str,
) -> Path:
    script = options.out_dir / "run_fpga_bench.sh"
    status_csv = options.out_dir / "run_status.csv"
    progress_csv = options.out_dir / "progress.csv"
    attempt_status_csv = options.out_dir / "attempt_status.csv"
    identity_env = options.out_dir / "fpga_identity.env"
    identity_json = options.out_dir / "fpga_identity.json"
    append_raw_csv = options.append_raw_csv.resolve() if options.append_raw_csv else None
    program_log = options.out_dir / "logs" / "program_fpga.log"
    retry_enabled = 1 if options.retry else 0
    program_fpga = 1 if options.program_fpga and units else 0
    slurm_inherited = has_slurm_allocation()
    # The raw DB is seeded before this script starts. Normal runs replace only
    # their seed rows; retry/resume paths replace stale matching measurements.
    raw_db_mode = raw_db_update_mode(options)
    retry_initial_timeout_s = _parse_timeout_seconds(options.blackbox_timeout) if options.retry else 0
    retry_max_rounds = options.retry_max_rounds if options.retry else 1
    retry_reset_cmd = tuple(shlex.split(options.retry_reset_cmd))
    retry_reset_add_device = 1 if retry_reset_cmd == tuple(shlex.split(DEFAULT_RETRY_RESET_CMD)) else 0
    capture_fpga_identity = 1 if units and (
        options.srun
        or slurm_inherited
        or options.program_fpga
        or (options.retry and bool(retry_reset_add_device))
    ) else 0
    status_columns = (
        "exec_key",
        "app",
        "returncode",
        "failure_phase",
        "failure_reason",
        "raw_csv",
        "power_csv",
        "power_summary",
        "measure_latency",
        "measure_power",
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
        f"export VORTEX_RT_PATH={_q(options.build_dir / 'runtime')}",
        f"export VORTEX_KN_PATH={_q(options.build_dir / 'kernel')}",
        f"mkdir -p {_q(options.out_dir / 'raw')} {_q(options.out_dir / 'power')} {_q(options.out_dir / 'logs')}",
        f"printf '%s\\n' {_q(','.join(status_columns))} > {_q(status_csv)}",
        f"printf '%s\\n' {_q(','.join(attempt_status_columns))} > {_q(attempt_status_csv)}",
        f"printf '%s\\n' {_q(','.join(PROGRESS_COLUMNS))} > {_q(progress_csv)}",
        f"export FPGA_BIN_DIR={_q(options.fpga_bin_dir)}",
        f"export TARGET={_q('hw')}",
        f"export PLATFORM={_q(options.platform)}",
        f"export DRIVER={_q('xrt')}",
        'export XRT_INI_PATH="${XRT_INI_PATH:-/dev/null}"',
        f"LATENCY_BENCH_REQUESTED_XRT_DEVICE_INDEX={_q('' if options.xrt_device_index is None else str(options.xrt_device_index))}",
        f"LATENCY_BENCH_REQUESTED_XRT_DEVICE_BDF={_q(options.xrt_device_bdf)}",
        f"LATENCY_BENCH_CAPTURE_FPGA_IDENTITY={capture_fpga_identity}",
        f"LATENCY_BENCH_FPGA_IDENTITY_ENV={_q(identity_env)}",
        f"LATENCY_BENCH_FPGA_IDENTITY_JSON={_q(identity_json)}",
        f"export PYTHONPATH={_q(repo_root())}:\"${{PYTHONPATH:-}}\"",
        f"export LATENCY_BENCH_RUN_ID={_q(options.run_id or default_run_id())}",
        f"source {_q(repo_root() / 'ci' / 'xrt_device_detect.sh')}",
        f"LATENCY_BENCH_PROGRAM_FPGA={program_fpga}",
        f"LATENCY_BENCH_PROGRAM_LOG={_q(program_log)}",
        f"LATENCY_BENCH_RETRY_ENABLED={retry_enabled}",
        f"LATENCY_BENCH_RETRY_MAX_ROUNDS={retry_max_rounds}",
        f"LATENCY_BENCH_RETRY_TIMEOUT_GROWTH={_q(str(options.retry_timeout_growth))}",
        f"LATENCY_BENCH_CURRENT_TIMEOUT_S={retry_initial_timeout_s}",
        f"LATENCY_BENCH_RETRY_RESET_WAIT={_q(options.retry_reset_wait)}",
        f"LATENCY_BENCH_RESET_CMD={_bash_array(retry_reset_cmd)}",
        f"LATENCY_BENCH_RESET_ADD_DEVICE={retry_reset_add_device}",
        "LATENCY_BENCH_LAST_RESET_RC=",
        "LATENCY_BENCH_XRT_DEVICE_INDEX=",
        "LATENCY_BENCH_XRT_DEVICE_BDF=",
        'if [[ -n "${NO_COLOR:-}" ]]; then',
        "  LATENCY_BENCH_PROGRESS_BLUE=",
        "  LATENCY_BENCH_PROGRESS_RESET=",
        "else",
        "  LATENCY_BENCH_PROGRESS_BLUE=$'\\033[34m'",
        "  LATENCY_BENCH_PROGRESS_RESET=$'\\033[0m'",
        "fi",
        "",
        "latency_bench_capture_fpga_identity() {",
        "  local smi index bdf host requested_index requested_bdf env_file json_file",
        "  requested_index=\"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_INDEX\"",
        "  requested_bdf=\"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_BDF\"",
        "  env_file=\"$LATENCY_BENCH_FPGA_IDENTITY_ENV\"",
        "  json_file=\"$LATENCY_BENCH_FPGA_IDENTITY_JSON\"",
        "  mkdir -p \"$(dirname \"$env_file\")\" \"$(dirname \"$json_file\")\"",
        "  smi=\"$(resolve_xrt_smi)\"",
        "  if [[ -z \"$smi\" ]]; then",
        "    printf '[latency-bench] xrt-smi not found; set XRT_SMI or PATH\\n' >&2",
        "    return 1",
        "  fi",
        "  unset XRT_DEVICE_INDEX XRT_DEVICE_BDF",
        "  if [[ -n \"$requested_bdf\" ]]; then",
        "    bdf=\"$requested_bdf\"",
        "    if [[ -n \"$requested_index\" ]]; then",
        "      index=\"$requested_index\"",
        "    elif ! index=\"$(bdf_to_fpga_id \"$bdf\")\"; then",
        "      printf '[latency-bench] failed to derive XRT index for requested BDF=%s\\n' \"$bdf\" >&2",
        "      return 1",
        "    fi",
        "  elif [[ -n \"$requested_index\" ]]; then",
        "    index=\"$requested_index\"",
        "    if ! probe_xrt_index \"$smi\" \"$index\"; then",
        "      printf '[latency-bench] requested XRT_DEVICE_INDEX=%s could not be checked with per-index xrt-smi; using resolver fallback\\n' \"$index\" >&2",
        "    fi",
        "    XRT_DEVICE_INDEX=\"$index\"",
        "    if ! bdf=\"$(resolve_xrt_user_bdf \"$index\")\"; then",
        "      printf '[latency-bench] failed to resolve BDF for requested XRT_DEVICE_INDEX=%s\\n' \"$index\" >&2",
        "      return 1",
        "    fi",
        "  else",
        "    if ! index=\"$(detect_single_accessible_xrt_index \"$smi\")\"; then",
        "      return 1",
        "    fi",
        "    XRT_DEVICE_INDEX=\"$index\"",
        "    if ! bdf=\"$(resolve_xrt_user_bdf \"$index\")\"; then",
        "      printf '[latency-bench] failed to resolve BDF for allocated XRT_DEVICE_INDEX=%s\\n' \"$index\" >&2",
        "      return 1",
        "    fi",
        "  fi",
        "  if [[ -z \"$index\" || -z \"$bdf\" ]]; then",
        "    printf '[latency-bench] resolved empty FPGA identity index=%s bdf=%s\\n' \"$index\" \"$bdf\" >&2",
        "    return 1",
        "  fi",
        "  export XRT_DEVICE_INDEX=\"$index\"",
        "  export XRT_DEVICE_BDF=\"$bdf\"",
        "  export LATENCY_BENCH_XRT_DEVICE_INDEX=\"$index\"",
        "  export LATENCY_BENCH_XRT_DEVICE_BDF=\"$bdf\"",
        "  export LATENCY_BENCH_XRT_SMI=\"$smi\"",
        "  host=\"$(hostname 2>/dev/null || printf unknown)\"",
        "  export LATENCY_BENCH_HOSTNAME=\"$host\"",
        "  {",
        "    printf 'XRT_DEVICE_INDEX=%s\\n' \"$XRT_DEVICE_INDEX\"",
        "    printf 'XRT_DEVICE_BDF=%s\\n' \"$XRT_DEVICE_BDF\"",
        "    printf 'XRT_SMI=%s\\n' \"$smi\"",
        "    printf 'HOSTNAME=%s\\n' \"$host\"",
        "    printf 'SLURM_JOB_ID=%s\\n' \"${SLURM_JOB_ID:-}\"",
        "    printf 'SLURM_STEP_ID=%s\\n' \"${SLURM_STEP_ID:-}\"",
        "  } > \"$env_file\"",
        "  \"${PYTHON:-python3}\" - \"$json_file\" <<'PY'",
        "import json",
        "import os",
        "import sys",
        "path = sys.argv[1]",
        "data = {",
        "    'xrt_device_index': os.environ.get('XRT_DEVICE_INDEX', ''),",
        "    'xrt_device_bdf': os.environ.get('XRT_DEVICE_BDF', ''),",
        "    'xrt_smi': os.environ.get('LATENCY_BENCH_XRT_SMI', ''),",
        "    'hostname': os.environ.get('LATENCY_BENCH_HOSTNAME', ''),",
        "    'slurm_job_id': os.environ.get('SLURM_JOB_ID', ''),",
        "    'slurm_step_id': os.environ.get('SLURM_STEP_ID', ''),",
        "}",
        "with open(path, 'w', encoding='utf-8') as fp:",
        "    json.dump(data, fp, indent=2, sort_keys=True)",
        "    fp.write('\\n')",
        "PY",
        "  printf '[latency-bench] FPGA identity: index=%s bdf=%s host=%s slurm_job=%s\\n' \"$XRT_DEVICE_INDEX\" \"$XRT_DEVICE_BDF\" \"$host\" \"${SLURM_JOB_ID:-}\"",
        "}",
        "",
        "latency_bench_init_fpga_identity() {",
        "  if [[ \"$LATENCY_BENCH_CAPTURE_FPGA_IDENTITY\" == \"1\" ]]; then",
        "    latency_bench_capture_fpga_identity",
        "    return",
        "  fi",
        "  if [[ -n \"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_INDEX\" ]]; then",
        "    export XRT_DEVICE_INDEX=\"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_INDEX\"",
        "  fi",
        "  if [[ -n \"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_BDF\" ]]; then",
        "    export XRT_DEVICE_BDF=\"$LATENCY_BENCH_REQUESTED_XRT_DEVICE_BDF\"",
        "  fi",
        "  export LATENCY_BENCH_XRT_DEVICE_INDEX=\"${XRT_DEVICE_INDEX:-}\"",
        "  export LATENCY_BENCH_XRT_DEVICE_BDF=\"${XRT_DEVICE_BDF:-}\"",
        "}",
        "",
        "latency_bench_program_fpga() {",
        "  local log_file=\"$LATENCY_BENCH_PROGRAM_LOG\"",
        "  local smi user_bdf xclbin rc",
        "  if [[ \"$LATENCY_BENCH_PROGRAM_FPGA\" != \"1\" ]]; then return 0; fi",
        "  xclbin=\"${FPGA_BIN_DIR}/vortex_afu.xclbin\"",
        "  mkdir -p \"$(dirname \"$log_file\")\"",
        "  if [[ ! -f \"$xclbin\" ]]; then",
        "    printf '[latency-bench] FPGA xclbin not found: %s\\n' \"$xclbin\" | tee -a \"$log_file\" >&2",
        "    return 1",
        "  fi",
        "  smi=\"$(resolve_xrt_smi)\"",
        "  if [[ -z \"$smi\" ]]; then",
        "    printf '[latency-bench] xrt-smi not found; set XRT_SMI or PATH\\n' | tee -a \"$log_file\" >&2",
        "    return 1",
        "  fi",
        "  user_bdf=\"${LATENCY_BENCH_XRT_DEVICE_BDF:-}\"",
        "  if [[ -z \"$user_bdf\" ]] && ! user_bdf=\"$(resolve_xrt_user_bdf \"${XRT_DEVICE_INDEX:-auto}\")\"; then",
        "    printf '[latency-bench] failed to resolve XRT user BDF\\n' | tee -a \"$log_file\" >&2",
        "    return 1",
        "  fi",
        "  if [[ -z \"$user_bdf\" ]]; then",
        "    printf '[latency-bench] resolved empty XRT user BDF\\n' | tee -a \"$log_file\" >&2",
        "    return 1",
        "  fi",
        "  printf '[latency-bench] programming FPGA: device=%s user=%s\\n' \"$user_bdf\" \"$xclbin\" | tee -a \"$log_file\"",
        "  set +e",
        "  \"$smi\" program --device \"$user_bdf\" --user \"$xclbin\" >> \"$log_file\" 2>&1",
        "  rc=$?",
        "  set -u",
        "  printf '[latency-bench] program rc=%s\\n' \"$rc\" >> \"$log_file\"",
        "  return \"$rc\"",
        "}",
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
        "  local reset_rc reset_bdf",
        "  local -a reset_cmd",
        "  LATENCY_BENCH_LAST_RESET_RC=",
        "  set +e",
        "  reset_cmd=(\"${LATENCY_BENCH_RESET_CMD[@]}\")",
        "  if [[ \"${LATENCY_BENCH_RESET_ADD_DEVICE:-0}\" == \"1\" ]]; then",
        "    reset_bdf=\"${LATENCY_BENCH_XRT_DEVICE_BDF:-${XRT_DEVICE_BDF:-}}\"",
        "    if [[ -z \"$reset_bdf\" ]]; then",
        "      printf '[latency-bench] retry reset has no saved XRT user BDF\\n' >> \"$log_file\"",
        "      LATENCY_BENCH_LAST_RESET_RC=1",
        "      set -u",
        "      return 1",
        "    fi",
        "    reset_cmd+=(\"-d\" \"$reset_bdf\")",
        "  fi",
        "  printf '[latency-bench] retry reset: direct %s\\n' \"${reset_cmd[*]}\" >> \"$log_file\"",
        "  printf 'y\\n' | timeout --kill-after=10s 60s \"${reset_cmd[@]}\" >> \"$log_file\" 2>&1",
        "  reset_rc=$?",
        "  set -u",
        "  printf '[latency-bench] retry reset rc=%s\\n' \"$reset_rc\" >> \"$log_file\"",
        "  if [[ \"$reset_rc\" == \"0\" ]]; then",
        "    if latency_bench_program_fpga; then",
        "      printf '[latency-bench] retry reset reprogram rc=0\\n' >> \"$log_file\"",
        "    else",
        "      reset_rc=$?",
        "      printf '[latency-bench] retry reset reprogram rc=%s\\n' \"$reset_rc\" >> \"$log_file\"",
        "    fi",
        "  fi",
        "  LATENCY_BENCH_LAST_RESET_RC=\"$reset_rc\"",
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
        "  if [[ \"$rc\" != \"0\" && -f \"$attempt_log\" ]] && grep -q \"Could not open device\" \"$attempt_log\"; then",
        "    printf 'xrt_device_open\\n'",
        "    return 0",
        "  fi",
        "  if [[ \"$rc\" != \"0\" ]]; then printf 'run\\n'; return 0; fi",
        "  printf '\\n'",
        "}",
        "",
        "latency_bench_power_failure_reason() {",
        "  local measure_power=\"$1\"",
        "  local power_summary=\"$2\"",
        "  local power_min_samples=\"$3\"",
        "  if [[ \"$measure_power\" != \"1\" ]]; then printf '\\n'; return 0; fi",
        "  \"${PYTHON:-python3}\" - \"$power_summary\" \"$power_min_samples\" <<'PY'",
        "import sys",
        "from tools.latency_bench.power_summary import read_power_summary",
        "from tools.latency_bench.status import power_sample_failure_reason",
        "summary = sys.argv[1]",
        "power_min_samples = int(sys.argv[2])",
        "reason = power_sample_failure_reason(",
        "    read_power_summary(summary),",
        "    measure_power=True,",
        "    power_min_samples=power_min_samples,",
        ")",
        "print(reason)",
        "PY",
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
    lines.extend([
        "if ! latency_bench_init_fpga_identity; then",
        "  echo \"[latency-bench] FPGA identity capture failed\" >&2",
        "  exit 1",
        "fi",
        "if ! latency_bench_program_fpga; then",
        "  echo \"[latency-bench] FPGA programming failed; see $LATENCY_BENCH_PROGRAM_LOG\" >&2",
        "  exit 1",
        "fi",
    ])

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
                f": > {_q(build_log)}",
                f"printf '[latency-bench] stage=build_begin app=%s log=%s\\n' {_q(app)} {_q(build_log)} | tee -a {_q(build_log)}",
                "set +e",
                f"{build_cmd} 2>&1 | tee -a {_q(build_log)}",
                "rc=\"${PIPESTATUS[0]}\"",
                "set -u",
                f"printf '[latency-bench] stage=build_end app=%s rc=%s log=%s\\n' {_q(app)} \"$rc\" {_q(build_log)} | tee -a {_q(build_log)}",
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
        "LATENCY_BENCH_RETRYABLE_FAILURES=0",
        "LATENCY_BENCH_TIMEOUT_RETRIES=0",
        "for exec_key in \"${LATENCY_BENCH_EXEC_KEYS[@]}\"; do LATENCY_BENCH_NEXT_SHOULD_RUN[\"$exec_key\"]=0; done",
        "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" == \"1\" ]]; then",
        "  echo \"[latency-bench] retry round ${LATENCY_BENCH_RETRY_ROUND}/${LATENCY_BENCH_RETRY_MAX_ROUNDS}, timeout=${LATENCY_BENCH_CURRENT_TIMEOUT_S}s\"",
        "fi",
    ])

    for idx, unit in enumerate(units, start=1):
        bench_arg_parts = [
            f"--warmup={unit.warmup}",
            f"--iterations={unit.iterations}",
            "--csv",
            f"--output={unit.raw_csv}",
        ]
        if not options.measure_latency:
            bench_arg_parts.append("--no-latency")
        if options.measure_power:
            bench_arg_parts.extend([
                "--power=separate",
                f"--power-csv={unit.power_csv}",
                f"--power-summary={unit.power_summary}",
                f"--power-target-samples={options.power_target_samples}",
                f"--power-latency-interval={options.power_latency_interval}",
            ])
            if options.power_auto_duration:
                bench_arg_parts.extend([
                    "--power-auto-duration=on",
                    f"--power-min-run-sec={options.power_min_run_sec}",
                    f"--power-max-run-sec={options.power_max_run_sec}",
                    f"--power-max-iterations={options.power_max_iterations}",
                    f"--power-min-interval={options.power_min_interval}",
                    f"--power-max-interval={options.power_max_interval}",
                ])
            if options.power_measure_latency:
                bench_arg_parts.append("--power-measure-latency=on")
            if options.power_kernel_iterations_auto:
                xclbin_info = options.power_xclbin_info or str(options.fpga_bin_dir / "vortex_afu.xclbin.info")
                fpga_freq_arg = "auto" if options.power_fpga_freq_mhz_auto else str(options.power_fpga_freq_mhz)
                bench_arg_parts.extend([
                    "--power-kernel-iterations=auto",
                    f"--power-target-sec={options.power_target_sec}",
                    f"--power-fpga-freq-mhz={fpga_freq_arg}",
                    f"--power-xclbin-info={xclbin_info}",
                ])
            elif options.power_kernel_iterations > 1:
                bench_arg_parts.append(f"--power-kernel-iterations={options.power_kernel_iterations}")
        if unit.args:
            bench_arg_parts.append(unit.args)
        bench_args = " ".join(bench_arg_parts)
        status_power_csv = unit.power_csv if options.measure_power else ""
        status_power_summary = unit.power_summary if options.measure_power else ""
        progress_power_args = ""
        raw_db_power_args = ""
        if options.measure_power:
            progress_power_args = (
                f"--power-csv {_q(unit.power_csv)} "
                f"--power-summary {_q(unit.power_summary)} "
                f"--power-min-samples {_q(str(options.power_min_samples))} "
            )
            raw_db_power_args = progress_power_args
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
            (
                f"printf '%s[{idx}/{len(units)}]%s %s\\n' "
                f"\"$LATENCY_BENCH_PROGRESS_BLUE\" \"$LATENCY_BENCH_PROGRESS_RESET\" "
                f"{_q(f'{unit.exec_key} app={unit.app} args={bench_args}')}"
            ),
            f"if [[ \"$LATENCY_BENCH_RETRY_ROUND\" == \"1\" ]]; then : > {_q(unit.log_file)}; fi",
            (
                f"printf '[latency-bench] stage=case_begin idx=%d total=%d exec_key=%s app=%s raw_csv=%s power_csv=%s power_summary=%s log=%s\\n' "
                f"{idx} {len(units)} {_q(unit.exec_key)} {_q(unit.app)} {_q(unit.raw_csv)} {_q(status_power_csv)} {_q(status_power_summary)} {_q(unit.log_file)} "
                f"| tee -a {_q(unit.log_file)}"
            ),
            (
                f"printf '[latency-bench] stage=case_args exec_key=%s args=%s\\n' "
                f"{_q(unit.exec_key)} {_q(bench_args)} | tee -a {_q(unit.log_file)}"
            ),
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
            f"  printf '[latency-bench] stage=case_build_failed exec_key=%s rc=%s build_log=%s\\n' {_q(unit.exec_key)} \"$rc\" \"$build_log\" | tee -a {_q(unit.log_file)}",
            f"  if [[ -n \"$build_log\" && -f \"$build_log\" ]]; then cat \"$build_log\" >> {_q(unit.log_file)}; fi",
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
            "    : > \"$attempt_log\"",
            (
                f"    printf '[latency-bench] stage=run_attempt_begin exec_key=%s retry_round=%d attempt=%d/%d timeout=%s attempt_log=%s\\n' "
                f"{_q(unit.exec_key)} \"$LATENCY_BENCH_RETRY_ROUND\" \"$attempt\" \"$max_attempts\" \"$blackbox_timeout_label\" \"$attempt_log\" "
                f"| tee -a {_q(unit.log_file)} \"$attempt_log\""
            ),
            f"    {blackbox_cmd} 2>&1 | tee -a {_q(unit.log_file)} \"$attempt_log\"",
            "    rc=\"${PIPESTATUS[0]}\"",
            (
                f"    printf '[latency-bench] stage=run_attempt_end exec_key=%s retry_round=%d attempt=%d/%d rc=%s attempt_log=%s\\n' "
                f"{_q(unit.exec_key)} \"$LATENCY_BENCH_RETRY_ROUND\" \"$attempt\" \"$max_attempts\" \"$rc\" \"$attempt_log\" "
                f"| tee -a {_q(unit.log_file)} \"$attempt_log\""
            ),
            f"    if [[ \"$rc\" == \"124\" || \"$rc\" == \"137\" ]]; then latency_bench_cleanup_timeout {_q(unit.raw_csv)} {_q(unit.log_file)}; fi",
            "    xrt_open_failure=\"\"",
            "    if [[ \"$rc\" != \"0\" && -f \"$attempt_log\" ]]; then",
            "      if grep -q 'failed to open cu context' \"$attempt_log\"; then xrt_open_failure=\"xrt_context_open\"; fi",
            "      if grep -q 'Could not open device' \"$attempt_log\"; then xrt_open_failure=\"xrt_device_open\"; fi",
            "    fi",
            "    if [[ -n \"$xrt_open_failure\" && \"$attempt\" -lt \"$max_attempts\" ]]; then",
            "      delay_s=$(latency_bench_retry_delay_s \"$attempt\")",
            f"      printf '[latency-bench] %s retry %d/%d after reset and %ss\\n' \"$xrt_open_failure\" \"$attempt\" \"$max_attempts\" \"$delay_s\" | tee -a {_q(unit.log_file)} \"$attempt_log\"",
            f"      if latency_bench_reset_fpga {_q(unit.log_file)}; then reset_ok=1; else reset_ok=0; fi",
            "      reset_ran=\"1\"",
            "      reset_rc=\"$LATENCY_BENCH_LAST_RESET_RC\"",
            "      if [[ \"$reset_ok\" != \"1\" ]]; then break; fi",
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
            f"  if [[ \"$rc\" == \"0\" && -z \"$failure_reason\" ]]; then",
            f"    power_failure_reason=$(latency_bench_power_failure_reason {_q(_bool_csv(options.measure_power))} {_q(status_power_summary)} {_q(str(options.power_min_samples))})",
            "    if [[ -n \"$power_failure_reason\" ]]; then failure_reason=\"$power_failure_reason\"; fi",
            "  fi",
            "fi",
            "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" == \"1\" && ( \"$failure_reason\" == \"timeout\" || \"$failure_reason\" == \"xrt_device_open\" ) ]]; then",
            f"  if latency_bench_reset_fpga {_q(unit.log_file)}; then :; else :; fi",
            "  reset_ran=\"1\"",
            "  reset_rc=\"$LATENCY_BENCH_LAST_RESET_RC\"",
            "fi",
            (
                f"printf '[latency-bench] stage=case_end exec_key=%s rc=%s failure_phase=%s failure_reason=%s elapsed_wall_s=%s reset_ran=%s reset_rc=%s\\n' "
                f"{_q(unit.exec_key)} \"$rc\" \"$failure_phase\" \"$failure_reason\" \"$elapsed_wall_s\" \"$reset_ran\" \"$reset_rc\" "
                f"| tee -a {_q(unit.log_file)}"
            ),
            (
                f"printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\\n' "
                f"{_q(unit.exec_key)} {_q(unit.app)} \"$rc\" \"$failure_phase\" \"$failure_reason\" "
                f"{_q(unit.raw_csv)} {_q(status_power_csv)} {_q(status_power_summary)} "
                f"{_q(_bool_csv(options.measure_latency))} {_q(_bool_csv(options.measure_power))} "
                f"{_q(unit.log_file)} \"$elapsed_wall_s\" "
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
                f"{progress_power_args}"
                f"--log-file {_q(unit.log_file)}"
            ),
            (
                f"\"${{PYTHON:-python3}}\" -m tools.latency_bench.raw_db "
                f"--output {_q(raw_db)} "
                f"--cases-csv {_q(options.out_dir / 'cases.csv')} "
                f"--exec-key {_q(unit.exec_key)} "
                f"--run-id \"$LATENCY_BENCH_RUN_ID\" "
                f"--fpga-bin-label {_q(options.fpga_bin_label)} "
                f"--fpga-bin-dir {_q(options.fpga_bin_dir)} "
                f"--xclbin-sha256 {_q(xclbin_sha256)} "
                f"--git-commit {_q(git.commit)} "
                f"--git-branch {_q(git.branch)} "
                f"--git-dirty {_q(git.dirty)} "
                f"--returncode \"$rc\" "
                f"--failure-phase \"$failure_phase\" "
                f"--failure-reason \"$failure_reason\" "
                f"--raw-csv {_q(unit.raw_csv)} "
                f"{raw_db_power_args}"
                f"--measure-latency {_q(_bool_csv(options.measure_latency))} "
                f"--measure-power {_q(_bool_csv(options.measure_power))} "
                f"--log-file {_q(unit.log_file)} "
                f"--elapsed-wall-s \"$elapsed_wall_s\" "
                f"--mode {_q(raw_db_mode)}"
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
            'if [[ "$failure_reason" == "timeout" ]]; then',
            "  LATENCY_BENCH_TIMEOUT_RETRIES=$((LATENCY_BENCH_TIMEOUT_RETRIES + 1))",
            "fi",
            'if [[ "$failure_reason" == "timeout" || "$failure_reason" == "power_samples_low" || ( "$failure_reason" == "xrt_device_open" && "$reset_rc" == "0" ) ]]; then',
            "  LATENCY_BENCH_RETRYABLE_FAILURES=$((LATENCY_BENCH_RETRYABLE_FAILURES + 1))",
            f"  LATENCY_BENCH_NEXT_SHOULD_RUN[{_q(unit.exec_key)}]=1",
            "fi",
            "fi",
        ])
    lines.extend([
        "",
        "if [[ \"$LATENCY_BENCH_RETRY_ENABLED\" != \"1\" ]]; then break; fi",
        "if [[ \"$LATENCY_BENCH_RETRYABLE_FAILURES\" == \"0\" ]]; then break; fi",
        "if [[ \"$LATENCY_BENCH_RETRY_ROUND\" -ge \"$LATENCY_BENCH_RETRY_MAX_ROUNDS\" ]]; then",
        "  echo \"[latency-bench] retry exhausted with ${LATENCY_BENCH_RETRYABLE_FAILURES} retryable failure(s)\"",
        "  break",
        "fi",
        "for exec_key in \"${LATENCY_BENCH_EXEC_KEYS[@]}\"; do LATENCY_BENCH_SHOULD_RUN[\"$exec_key\"]=\"${LATENCY_BENCH_NEXT_SHOULD_RUN[$exec_key]:-0}\"; done",
        "if [[ \"$LATENCY_BENCH_TIMEOUT_RETRIES\" != \"0\" ]]; then",
        "  LATENCY_BENCH_CURRENT_TIMEOUT_S=$(latency_bench_grow_timeout_s \"$LATENCY_BENCH_CURRENT_TIMEOUT_S\" \"$LATENCY_BENCH_RETRY_TIMEOUT_GROWTH\")",
        "fi",
        "LATENCY_BENCH_RETRY_ROUND=$((LATENCY_BENCH_RETRY_ROUND + 1))",
        "done",
    ])
    lines.append("exit 0")
    script.write_text("\n".join(lines) + "\n")
    script.chmod(0o755)
    return script


def add_git_metadata(results: pd.DataFrame, git: GitMetadata) -> pd.DataFrame:
    rows = results.copy()
    rows.insert(0, "git_dirty", git.dirty)
    rows.insert(0, "git_branch", git.branch)
    rows.insert(0, "git_commit", git.commit)
    return rows


def run_suite(suite: BenchSuite, options: RunOptions) -> int:
    git = collect_git_metadata()
    out_root = options.out_dir
    run_id = options.run_id or os.environ.get("LATENCY_BENCH_RUN_ID") or default_run_id()
    run_dir = out_root / "runs" / run_id
    run_options = replace(
        options,
        out_dir=run_dir,
        run_id=run_id,
        skip_existing_columns=normalize_skip_existing_columns(options.skip_existing_columns),
    )
    if run_options.power_kernel_iterations_auto and not run_options.measure_latency:
        run_options = replace(run_options, measure_latency=True)

    out_root.mkdir(parents=True, exist_ok=True)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "raw").mkdir(exist_ok=True)
    (run_dir / "power").mkdir(exist_ok=True)
    (run_dir / "logs").mkdir(exist_ok=True)

    validate_inputs(run_options)
    xclbin_sha256 = _current_xclbin_sha(run_options.fpga_bin_dir)
    units = build_execution_units(suite, run_dir)
    skipped_existing_exec_keys: tuple[str, ...] = ()
    units_to_run = units
    if options.skip_existing:
        skipped_existing_exec_keys = find_existing_pass_exec_keys(
            out_root / "raw_db.csv",
            units,
            fpga_bin_label=run_options.fpga_bin_label,
            xclbin_sha256=xclbin_sha256,
            measure_latency=run_options.measure_latency,
            measure_power=run_options.measure_power,
            power_min_samples=run_options.power_min_samples,
            skip_existing_columns=run_options.skip_existing_columns,
        )
        skipped = set(skipped_existing_exec_keys)
        units_to_run = [unit for unit in units if unit.exec_key not in skipped]
    write_cases_csv(suite, run_dir)
    write_suite_snapshots(suite, run_dir)
    script = write_run_script(
        suite,
        run_options,
        units_to_run,
        raw_db=out_root / "raw_db.csv",
        git=git,
        xclbin_sha256=xclbin_sha256,
    )
    slurm_mode = slurm_run_mode(options)
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
        "xrt_device_index_request": "auto" if options.xrt_device_index is None else str(options.xrt_device_index),
        "xrt_device_bdf": options.xrt_device_bdf,
        "fpga_identity_env": str(run_dir / "fpga_identity.env"),
        "fpga_identity_json": str(run_dir / "fpga_identity.json"),
        "slurm_mode": slurm_mode,
        "srun": options.srun,
        "srun_args": list(options.srun_args),
        "program_fpga": options.program_fpga and bool(units_to_run),
        "measure_latency": run_options.measure_latency,
        "measure_power": run_options.measure_power,
        "power_measure_latency": run_options.power_measure_latency if run_options.measure_power else False,
        "power_mode": "separate" if run_options.measure_power else "off",
        "power_auto_duration": run_options.power_auto_duration if run_options.measure_power else False,
        "power_min_run_sec": run_options.power_min_run_sec,
        "power_max_run_sec": run_options.power_max_run_sec,
        "power_max_iterations": run_options.power_max_iterations,
        "power_target_samples": run_options.power_target_samples,
        "power_latency_interval": run_options.power_latency_interval,
        "power_min_interval": run_options.power_min_interval,
        "power_max_interval": run_options.power_max_interval,
        "power_min_samples": run_options.power_min_samples,
        "power_kernel_iterations": run_options.power_kernel_iterations,
        "power_kernel_iterations_auto": run_options.power_kernel_iterations_auto,
        "power_target_sec": run_options.power_target_sec,
        "power_fpga_freq_mhz": run_options.power_fpga_freq_mhz,
        "power_fpga_freq_mhz_auto": run_options.power_fpga_freq_mhz_auto,
        "power_xclbin_info": run_options.power_xclbin_info,
        "power_dir": str(run_dir / "power"),
        "program_log": str(run_dir / "logs" / "program_fpga.log"),
        "xrt_smi": os.environ.get("XRT_SMI", "/opt/xilinx/xrt/bin/xrt-smi"),
        "blackbox_args": list(options.blackbox_args),
        "blackbox_timeout": options.blackbox_timeout,
        "configs": str(options.configs) if options.configs else "",
        "configs_extra": options.configs_extra,
        "execution_count": len(units),
        "run_execution_count": len(units_to_run),
        "skip_existing": options.skip_existing,
        "skip_existing_columns": list(run_options.skip_existing_columns),
        "prebuild": options.prebuild,
        "case_filters": list(options.case_filters),
        "retry": options.retry,
        "retry_max_rounds": options.retry_max_rounds,
        "retry_timeout_growth": options.retry_timeout_growth,
        "retry_reset_wait": options.retry_reset_wait,
        "retry_reset_cmd": options.retry_reset_cmd,
        "retry_reset_add_device": tuple(shlex.split(options.retry_reset_cmd)) == tuple(shlex.split(DEFAULT_RETRY_RESET_CMD)),
        "skipped_existing_count": len(skipped_existing_exec_keys),
        "skipped_existing_exec_keys": list(skipped_existing_exec_keys),
        "script": str(script),
        "dry_run": options.dry_run,
        "append_raw_csv": str(options.append_raw_csv) if options.append_raw_csv else "",
    })
    publish_run_latest(
        run_dir,
        out_root,
        (
            "cases.csv",
            "suite.yaml",
            "suite.expanded.yaml",
            "manifest.json",
            "run_fpga_bench.sh",
        ),
        run_id=run_id,
        status="dry_run" if options.dry_run else "running",
    )
    publish_current_cases(suite, run_dir, out_root)

    if options.dry_run:
        print(f"dry-run: wrote {script}")
        print(f"dry-run: expanded {len(suite.cases)} cases into {len(units)} unique executions")
        if options.skip_existing:
            print(f"dry-run: skipped {len(skipped_existing_exec_keys)} existing pass executions")
        return 0

    seeded_rows = seed_raw_db_cases(
        suite,
        units_to_run,
        raw_db=out_root / "raw_db.csv",
        options=run_options,
        git=git,
        xclbin_sha256=xclbin_sha256,
    )
    if seeded_rows:
        print(f"pre-seeded {seeded_rows} row(s) in {out_root / 'raw_db.csv'}", flush=True)

    cmd = run_script_command(script, options)
    print("+ " + " ".join(shlex.quote(part) for part in cmd), flush=True)
    try:
        rc = subprocess.call(cmd, env=os.environ.copy())
    except KeyboardInterrupt:
        publish_run_latest(
            run_dir,
            out_root,
            (
                "cases.csv",
                "manifest.json",
                "run_status.csv",
                "progress.csv",
                "attempt_status.csv",
            ),
            run_id=run_id,
            status="interrupted",
        )
        publish_current_cases(suite, run_dir, out_root)
        raise

    results = build_results(suite, run_dir, options.fpga_bin_dir, power_min_samples=run_options.power_min_samples)
    results = add_git_metadata(results, git)
    summary = build_summary(results)
    results.to_csv(run_dir / "results.csv", index=False)
    summary.to_csv(run_dir / "summary.csv", index=False)
    publish_run_latest(
        run_dir,
        out_root,
        (
            "cases.csv",
            "suite.yaml",
            "suite.expanded.yaml",
            "manifest.json",
            "run_fpga_bench.sh",
            "run_status.csv",
            "progress.csv",
            "attempt_status.csv",
            "results.csv",
            "summary.csv",
            "fpga_identity.env",
            "fpga_identity.json",
        ),
        run_id=run_id,
        status="completed" if rc == 0 else "failed",
    )
    publish_current_cases(suite, run_dir, out_root)
    append_results = results
    if options.skip_existing:
        executed_keys = {unit.exec_key for unit in units_to_run}
        append_results = results[results["exec_key"].isin(executed_keys)]
    print(f"wrote {run_dir / 'results.csv'}")
    print(f"wrote {run_dir / 'summary.csv'}")
    if append_results.empty:
        print(f"no new rows written to {out_root / 'raw_db.csv'}")
    elif options.skip_existing:
        unique_count = int(append_results["exec_key"].nunique())
        print(f"live-updated {out_root / 'raw_db.csv'} with {unique_count} executed row(s)")
    else:
        print(f"live-updated {out_root / 'raw_db.csv'}")
    return rc
