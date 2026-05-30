from __future__ import annotations

import csv
import os
import shutil
import shlex
import subprocess
from datetime import datetime, timezone
from dataclasses import dataclass, replace
from pathlib import Path

import pandas as pd
import yaml

from .fpga_bins import FpgaBinConfig, resolve_fpga_bin, resolve_fpga_bin_config
from .report import build_results, build_summary, write_manifest
from .suite import DEFAULT_BLACKBOX_ARGS, BenchCase, BenchSuite, suite_to_expanded_yaml, suite_to_rows


DEFAULT_SRUN_ARGS = (
    "--gres=fpga:u55c:1",
    "--cpus-per-task=4",
    "--mem=16G",
    "--time=01:00:00",
)


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
    configs_extra: str = ""
    blackbox_args: tuple[str, ...] = DEFAULT_BLACKBOX_ARGS
    blackbox_timeout: str = ""
    srun: bool = True
    srun_args: tuple[str, ...] = DEFAULT_SRUN_ARGS
    dry_run: bool = False
    append_raw_csv: Path | None = None
    run_id: str | None = None


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


def _q(value: str | Path) -> str:
    return shlex.quote(str(value))


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
    append_raw_csv = options.append_raw_csv.resolve() if options.append_raw_csv else None
    lines = [
        "#!/usr/bin/env bash",
        "set -uo pipefail",
        f"cd {_q(options.build_dir)}",
        f"mkdir -p {_q(options.out_dir / 'raw')} {_q(options.out_dir / 'logs')}",
        f"printf 'exec_key,app,returncode,raw_csv,log_file\\n' > {_q(status_csv)}",
        f"export FPGA_BIN_DIR={_q(options.fpga_bin_dir)}",
        f"export TARGET={_q('hw')}",
        f"export PLATFORM={_q(options.platform)}",
        f"export DRIVER={_q('xrt')}",
        f"export XRT_DEVICE_INDEX={_q(str(options.xrt_device_index))}",
    ]
    if append_raw_csv:
        lines.extend([
            f"export PYTHONPATH={_q(repo_root())}:\"${{PYTHONPATH:-}}\"",
            f"export LATENCY_BENCH_RUN_ID={_q(options.run_id or default_run_id())}",
        ])
    if options.configs_extra:
        lines.append(f"export CONFIGS=\"${{CONFIGS:-}} {options.configs_extra}\"")

    for idx, unit in enumerate(units, start=1):
        bench_args = f"--warmup={unit.warmup} --iterations={unit.iterations} --csv --output={unit.raw_csv} {unit.args}"
        blackbox_args = " ".join(_q(arg) for arg in options.blackbox_args)
        blackbox_args = f"{blackbox_args} " if blackbox_args else ""
        blackbox_cmd = (
            f"./ci/blackbox.sh {blackbox_args}--driver=xrt --bench --app={_q(unit.app)} "
            f"--args={_q(bench_args)} --log={_q(unit.log_file)}"
        )
        if options.blackbox_timeout:
            blackbox_cmd = f"timeout --foreground --kill-after=30s {_q(options.blackbox_timeout)} {blackbox_cmd}"
        lines.extend([
            "",
            f"echo '[{idx}/{len(units)}] {unit.exec_key} app={unit.app} args={bench_args}'",
            "set +e",
            blackbox_cmd,
            "rc=$?",
            "set -u",
            (
                f"printf '%s,%s,%s,%s,%s\\n' "
                f"{_q(unit.exec_key)} {_q(unit.app)} \"$rc\" {_q(unit.raw_csv)} {_q(unit.log_file)} "
                f">> {_q(status_csv)}"
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
                    f"--raw-csv {_q(unit.raw_csv)} "
                    f"--log-file {_q(unit.log_file)}"
                ),
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
    "raw_csv",
    "log_file",
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


def append_raw_db(results: pd.DataFrame, out_root: Path, *, run_id: str, fpga_bin_label: str) -> None:
    if results.empty:
        return

    rows = results.copy()
    rows.insert(0, "timestamp_utc", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    rows.insert(0, "run_id", run_id)
    rows.insert(2, "fpga_bin_label", fpga_bin_label)
    rows = rows.reindex(columns=RAW_DB_COLUMNS)

    raw_db = out_root / "raw_db.csv"
    raw_db.parent.mkdir(parents=True, exist_ok=True)
    write_header = not raw_db.exists() or raw_db.stat().st_size == 0
    rows.to_csv(raw_db, mode="a", header=write_header, index=False)


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
    write_cases_csv(suite, run_dir)
    write_suite_snapshots(suite, run_dir)
    script = write_run_script(suite, run_options, units)
    write_manifest(suite, run_dir, {
        "run_id": run_id,
        "out_root": str(out_root),
        "run_dir": str(run_dir),
        "raw_db": str(out_root / "raw_db.csv"),
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
        "configs_extra": options.configs_extra,
        "execution_count": len(units),
        "script": str(script),
        "dry_run": options.dry_run,
        "append_raw_csv": str(options.append_raw_csv) if options.append_raw_csv else "",
    })

    if options.dry_run:
        print(f"dry-run: wrote {script}")
        print(f"dry-run: expanded {len(suite.cases)} cases into {len(units)} unique executions")
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
    append_raw_db(results, out_root, run_id=run_id, fpga_bin_label=options.fpga_bin_label)
    print(f"wrote {run_dir / 'results.csv'}")
    print(f"wrote {run_dir / 'summary.csv'}")
    print(f"appended {out_root / 'raw_db.csv'}")
    return rc
