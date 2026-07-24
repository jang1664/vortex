from __future__ import annotations

import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .backends import Backend, BackendContext, has_slurm_allocation, make_backend
from .models import CaseResult, RegressionCase
from .reporting import (
    render_case_table,
    render_result_table,
    summarize_results,
    write_manifest,
    write_results,
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def parse_duration(value: str) -> float:
    text = value.strip().lower()
    if not text:
        raise ValueError("timeout must not be empty")
    multipliers = {"s": 1.0, "m": 60.0, "h": 3600.0}
    suffix = text[-1]
    if suffix in multipliers:
        number = text[:-1]
        multiplier = multipliers[suffix]
    else:
        number = text
        multiplier = 1.0
    try:
        seconds = float(number) * multiplier
    except ValueError as exc:
        raise ValueError(f"invalid timeout {value!r}; use a number with optional s, m, or h") from exc
    if seconds <= 0:
        raise ValueError("timeout must be greater than zero")
    return seconds


def create_manifest(
    *,
    run_dir: Path,
    repo_root: Path,
    build_dir: Path,
    backend: str,
    fpga_alias: str,
    timeout_sec: float,
    verbose: bool,
    cases: list[RegressionCase],
    argv: list[str],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "run_id": run_dir.name,
        "created_at": utc_now(),
        "repo_root": str(repo_root),
        "build_dir": str(build_dir),
        "run_dir": str(run_dir),
        "backend": backend,
        "fpga_alias": fpga_alias,
        "timeout_sec": timeout_sec,
        "verbose": verbose,
        "argv": argv,
        "cases": [asdict(case) for case in cases],
    }


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open() as stream:
        manifest = json.load(stream)
    if manifest.get("schema_version") != 1:
        raise ValueError(f"unsupported manifest schema: {manifest.get('schema_version')!r}")
    return manifest


def _terminate_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def _last_log_message(path: Path) -> str:
    try:
        lines = [line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
    except OSError:
        return ""
    return lines[-1] if lines else ""


def execute_case(
    *,
    case: RegressionCase,
    backend: Backend,
    context: BackendContext,
    timeout_sec: float,
    log_path: Path,
    verbose: bool,
) -> CaseResult:
    started_at = utc_now()
    started_monotonic = time.monotonic()
    command = backend.case_command(context, case)
    status = "ERROR"
    returncode: int | None = None
    message = ""

    try:
        with log_path.open("w") as log_stream:
            log_stream.write(f"[regression-runner] command={shlex.join(command)}\n")
            log_stream.flush()
            process = subprocess.Popen(
                command,
                cwd=context.build_dir,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                start_new_session=True,
            )

            def copy_output() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    log_stream.write(line)
                    log_stream.flush()
                    if verbose:
                        print(line, end="", flush=True)

            output_thread = threading.Thread(target=copy_output, daemon=True)
            output_thread.start()
            try:
                returncode = process.wait(timeout=timeout_sec)
                status = "PASS" if returncode == 0 else "FAIL"
            except subprocess.TimeoutExpired:
                status = "TIMEOUT"
                message = f"case exceeded timeout of {timeout_sec:g}s"
                _terminate_process_group(process)
                returncode = process.returncode
            except KeyboardInterrupt:
                status = "INTERRUPTED"
                message = "interrupted by user"
                _terminate_process_group(process)
                returncode = process.returncode
            finally:
                output_thread.join(timeout=5)
                if process.stdout is not None:
                    process.stdout.close()
    except OSError as exc:
        status = "ERROR"
        message = str(exc)

    ended_at = utc_now()
    duration_sec = time.monotonic() - started_monotonic
    if not message and status != "PASS":
        message = _last_log_message(log_path)
    return CaseResult(
        order=case.order,
        case_id=case.case_id,
        test=case.test,
        args=case.args,
        backend=backend.name,
        fpga_alias=context.fpga_alias,
        status=status,
        returncode=returncode,
        started_at=started_at,
        ended_at=ended_at,
        duration_sec=duration_sec,
        log=str(log_path),
        message=message,
    )


def run_worker(manifest_path: Path, backend_override: Backend | None = None) -> int:
    manifest = load_manifest(manifest_path)
    run_dir = Path(manifest["run_dir"]).resolve()
    log_dir = run_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    cases = [RegressionCase(**item) for item in manifest["cases"]]
    backend = backend_override or make_backend(manifest["backend"])
    context = BackendContext(
        repo_root=Path(manifest["repo_root"]).resolve(),
        build_dir=Path(manifest["build_dir"]).resolve(),
        fpga_alias=manifest["fpga_alias"],
    )
    backend.validate(context)

    results: list[CaseResult] = []
    interrupted = False
    for index, case in enumerate(cases, start=1):
        print(f"[{index}/{len(cases)}] RUN {case.test} {case.args}".rstrip(), flush=True)
        result = execute_case(
            case=case,
            backend=backend,
            context=context,
            timeout_sec=float(manifest["timeout_sec"]),
            log_path=log_dir / f"{case.case_id}.log",
            verbose=bool(manifest["verbose"]),
        )
        results.append(result)
        write_results(run_dir, manifest, results)
        print(
            f"[{index}/{len(cases)}] {result.status} {case.test} "
            f"({result.duration_sec:.2f}s)",
            flush=True,
        )
        if result.status == "INTERRUPTED":
            interrupted = True
            break

    print()
    print(render_result_table(results))
    print(summarize_results(results))
    failures = [result for result in results if result.status != "PASS"]
    if failures:
        print("\nFailure details:")
        for result in failures:
            print(f"- {result.test} [{result.status}]: {result.message or result.log}")
    return 1 if failures or interrupted else 0


def run_controller(
    *,
    manifest_path: Path,
    backend: Backend,
    no_srun: bool,
    env: dict[str, str] | None = None,
) -> int:
    manifest = load_manifest(manifest_path)
    if no_srun or has_slurm_allocation(env):
        return run_worker(manifest_path, backend_override=backend)

    command = backend.allocation_command(manifest_path)
    completed = subprocess.run(
        command,
        cwd=Path(manifest["repo_root"]),
        env=env,
        check=False,
    )
    return completed.returncode


def print_dry_run(
    manifest: dict[str, Any],
    backend: Backend,
    context: BackendContext,
) -> None:
    cases = [RegressionCase(**item) for item in manifest["cases"]]
    print(render_case_table(cases))
    print("\nCommands:")
    for case in cases:
        print(shlex.join(backend.case_command(context, case)))
