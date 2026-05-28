from __future__ import annotations

import csv
import os
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .report import build_results, build_summary, write_manifest
from .suite import DEFAULT_BLACKBOX_ARGS, BenchCase, BenchSuite, suite_to_rows


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
    configs_extra: str = ""
    blackbox_args: tuple[str, ...] = DEFAULT_BLACKBOX_ARGS
    srun: bool = True
    srun_args: tuple[str, ...] = DEFAULT_SRUN_ARGS
    dry_run: bool = False


def normalize_fpga_bin(path: Path) -> Path:
    path = path.resolve()
    return path.parent if path.name == "vortex_afu.xclbin" else path


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


def write_cases_csv(suite: BenchSuite, out_dir: Path) -> None:
    rows = suite_to_rows(suite)
    with (out_dir / "cases.csv").open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def write_run_script(suite: BenchSuite, options: RunOptions, units: list[ExecutionUnit]) -> Path:
    script = options.out_dir / "run_fpga_bench.sh"
    status_csv = options.out_dir / "run_status.csv"
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
    if options.configs_extra:
        lines.append(f"export CONFIGS=\"${{CONFIGS:-}} {options.configs_extra}\"")

    for idx, unit in enumerate(units, start=1):
        bench_args = f"--warmup={unit.warmup} --iterations={unit.iterations} --csv --output={unit.raw_csv} {unit.args}"
        blackbox_args = " ".join(_q(arg) for arg in options.blackbox_args)
        blackbox_args = f"{blackbox_args} " if blackbox_args else ""
        lines.extend([
            "",
            f"echo '[{idx}/{len(units)}] {unit.exec_key} app={unit.app} args={bench_args}'",
            "set +e",
            (
                f"./ci/blackbox.sh {blackbox_args}--driver=xrt --bench --app={_q(unit.app)} "
                f"--args={_q(bench_args)} --log={_q(unit.log_file)}"
            ),
            "rc=$?",
            "set -u",
            (
                f"printf '%s,%s,%s,%s,%s\\n' "
                f"{_q(unit.exec_key)} {_q(unit.app)} \"$rc\" {_q(unit.raw_csv)} {_q(unit.log_file)} "
                f">> {_q(status_csv)}"
            ),
        ])
    lines.append("exit 0")
    script.write_text("\n".join(lines) + "\n")
    script.chmod(0o755)
    return script


def run_suite(suite: BenchSuite, options: RunOptions) -> int:
    options.out_dir.mkdir(parents=True, exist_ok=True)
    (options.out_dir / "raw").mkdir(exist_ok=True)
    (options.out_dir / "logs").mkdir(exist_ok=True)

    validate_inputs(options)
    units = build_execution_units(suite, options.out_dir)
    write_cases_csv(suite, options.out_dir)
    script = write_run_script(suite, options, units)
    write_manifest(suite, options.out_dir, {
        "build_dir": str(options.build_dir),
        "fpga_bin_dir": str(options.fpga_bin_dir),
        "platform": options.platform,
        "xrt_device_index": options.xrt_device_index,
        "blackbox_args": list(options.blackbox_args),
        "configs_extra": options.configs_extra,
        "execution_count": len(units),
        "script": str(script),
        "dry_run": options.dry_run,
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

    results = build_results(suite, options.out_dir, options.fpga_bin_dir)
    summary = build_summary(results)
    results.to_csv(options.out_dir / "results.csv", index=False)
    summary.to_csv(options.out_dir / "summary.csv", index=False)
    print(f"wrote {options.out_dir / 'results.csv'}")
    print(f"wrote {options.out_dir / 'summary.csv'}")
    return rc
