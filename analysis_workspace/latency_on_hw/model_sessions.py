"""Host coordinator and model workers that own one FPGA for all measurements."""
from __future__ import annotations

import argparse
import csv
from contextlib import ExitStack
from dataclasses import asdict, dataclass, replace
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import time
import uuid

import pipeline

WORKER_ENV = "VORTEX_LATENCY_MODEL_WORKER"


def reject_allocation() -> None:
    if os.environ.get("SLURM_JOB_ID") or os.environ.get("SLURM_STEP_ID"):
        raise ValueError("Launch workflow.py outside Slurm; the workflow allocates one FPGA per model session.")


@dataclass(frozen=True)
class SlurmSettings:
    model_execution: str = "serial"
    parallel_fallback: str = "error"
    partition: str = "fpga"
    cpus: int = 4
    memory: str = "16G"
    time_limit: str = "7-00:00:00"
    allocation_wait: int = 30


def add_arguments(parser: argparse.ArgumentParser) -> None:
    group = parser.add_argument_group("model FPGA allocation")
    group.add_argument("--model-execution", choices=("serial", "parallel"), default="serial")
    group.add_argument("--parallel-fallback", choices=("error", "serial"), default="error")
    group.add_argument("--slurm-partition", default="fpga")
    group.add_argument("--slurm-cpus", type=int, default=4)
    group.add_argument("--slurm-mem", default="16G")
    group.add_argument("--slurm-time", default="7-00:00:00")
    group.add_argument("--allocation-wait", type=int, default=30,
                       help="Seconds srun may wait for resources, including races after the availability check.")


def memory_mb(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([KMGTP]?)", value.upper())
    if not match:
        raise ValueError("--slurm-mem must be a positive size such as 16G")
    multiplier = {"K": 1 / 1024, "": 1, "M": 1, "G": 1024,
                  "T": 1024 ** 2, "P": 1024 ** 3}[match[2]]
    return max(1, int(int(match[1]) * multiplier))


def available_fpga_slots(options: SlurmSettings) -> int:
    """Count unallocated U55C GRES with sufficient CPU and memory on usable nodes."""
    result = subprocess.run(["scontrol", "show", "nodes", "-o"],
                            check=True, text=True, capture_output=True)
    slots = 0
    for line in result.stdout.splitlines():
        fields = dict(re.findall(r"(\w+)=([^\s]+)", line))
        if options.partition not in fields.get("Partitions", "").split(","):
            continue
        states = fields.get("State", "").split("+")
        if states[0] not in {"IDLE", "MIXED", "ALLOCATED"} or any(
                flag in {"DRAIN", "DRAINED", "DOWN", "FAIL", "MAINT", "RESERVED", "NOT_RESPONDING"}
                for flag in states[1:]):
            continue
        configured = dict(item.split("=", 1) for item in fields.get("CfgTRES", "").split(",") if "=" in item)
        allocated = dict(item.split("=", 1) for item in fields.get("AllocTRES", "").split(",") if "=" in item)
        # The untyped allocation is a conservative fallback on clusters that omit typed TRES.
        free = int(configured.get("gres/fpga:u55c", "0")) - int(
            allocated.get("gres/fpga:u55c", allocated.get("gres/fpga", "0")))
        cpu = (int(fields.get("CPUEfctv", fields.get("CPUTot", "0"))) -
               int(fields.get("CPUAlloc", "0"))) // options.cpus
        mem = (int(fields.get("RealMemory", "0")) - int(fields.get("AllocMem", "0"))) // memory_mb(options.memory)
        slots += max(0, min(free, cpu, mem))
    return slots


def execution_mode(options: SlurmSettings, models: tuple[str, ...], slots: int) -> str:
    if options.model_execution == "serial" or len(models) < 2:
        return "serial"
    if slots >= len(models):
        return "parallel"
    if options.parallel_fallback == "serial":
        return "serial"
    raise ValueError(f"Parallel execution needs {len(models)} free U55C FPGA slots; found {slots}. "
                     "Use --parallel-fallback serial to allow sequential execution.")


def _settings_payload(settings: pipeline.PipelineSettings) -> dict:
    return {key: str(value) if isinstance(value, Path) else value
            for key, value in asdict(settings).items()}


def _settings_from_payload(payload: dict) -> pipeline.PipelineSettings:
    values = dict(payload)
    for key in ("workspace", "state_base", "candidate_map"):
        if values.get(key) is not None:
            values[key] = Path(values[key])
    for key in ("models", "formats", "candidates", "case_filters", "kernel_variants", "generation_options"):
        values[key] = tuple(values[key])
    return pipeline.PipelineSettings(**values)


def capture_identity(settings: pipeline.PipelineSettings) -> dict:
    detector = settings.workspace.parents[1] / "ci/xrt_device_detect.sh"
    script = '\n'.join((
        'set -euo pipefail', 'source "$1"',
        'unset XRT_DEVICE_INDEX XRT_DEVICE_BDF',
        'smi="$(resolve_xrt_smi)"',
        'index="$(detect_single_accessible_xrt_index "$smi")"',
        'export XRT_DEVICE_INDEX="$index"',
        'bdf="$(resolve_xrt_user_bdf "$index")"',
        'printf "%s\\n%s\\n" "$index" "$bdf"',
    ))
    result = subprocess.run(["bash", "-c", script, "model-identity", str(detector)],
                            check=True, text=True, capture_output=True)
    index, bdf = result.stdout.strip().splitlines()
    os.environ.update(XRT_DEVICE_INDEX=index, XRT_DEVICE_BDF=bdf)
    return {"hostname": socket.gethostname(), "xrt_device_index": index, "xrt_device_bdf": bdf}


def pin_model(settings: pipeline.PipelineSettings, model: str, identity: dict) -> None:
    root = settings.result_root(model)
    path = root / "model_fpga.json"
    # Check historical run identities as well, before establishing a new ledger.
    recorded = [path] if path.is_file() else []
    historical = []
    if root.exists():
        historical = list(root.rglob("fpga_identity.json"))
        recorded += historical
    for previous in recorded:
        old = json.loads(previous.read_text())
        if any(old.get(key) != identity[key] for key in ("hostname", "xrt_device_bdf")):
            raise ValueError(f"{model} must stay on its original FPGA: {previous} records "
                             f"{old.get('hostname')}/{old.get('xrt_device_bdf')}, allocation is "
                             f"{identity['hostname']}/{identity['xrt_device_bdf']}. "
                             "Use a new tag for measurements on another board.")
    known_runs = {previous.parent.name for previous in historical if previous.parent.name != "latest"}
    if root.exists():
        for database in root.rglob("raw_db.csv"):
            with database.open(newline="") as source:
                for row in csv.DictReader(source):
                    if row.get("status") == "pass" and row.get("run_id") not in known_runs:
                        raise ValueError(f"Cannot establish {model}'s FPGA identity: successful run "
                                         f"{row.get('run_id')} in {database} has no fpga_identity.json. "
                                         "Use a new tag instead of mixing unverified historical measurements.")
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = dict(identity, slurm_job_id=os.environ.get("SLURM_JOB_ID", ""))
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n")
        temporary.replace(path)


def worker_main(arguments: list[str]) -> int:
    if not (os.environ.get("SLURM_JOB_ID") or os.environ.get("SLURM_STEP_ID")):
        raise ValueError("The internal model worker requires a Slurm allocation.")
    payload = json.loads(Path(arguments[0]).read_text())
    settings = _settings_from_payload(payload["settings"])
    os.environ[WORKER_ENV] = "1"
    os.environ["PYTHON"] = settings.python
    identity = capture_identity(settings)
    # The HW driver supports an override; isolate its status page across boards.
    os.environ["VORTEX_SHM_PATH"] = (f"/dev/shm/vortex_status_uid_{os.getuid()}_"
                                    + identity["xrt_device_bdf"].replace(":", "_").replace(".", "_"))
    summaries = []
    code = 0
    for model in settings.models:
        current = replace(settings, models=(model,))
        pin_model(current, model, identity)
        code, summary = pipeline.run_pipeline(current, first=payload["first"],
                                              last=payload["last"], rerun=payload["rerun"])
        summaries.append(summary)
        if code:
            break
    Path(payload["summary_path"]).write_text(json.dumps(
        {"identity": identity, "models": summaries, "exit_code": code}, indent=2) + "\n")
    return code


def _hardware_pending(settings: pipeline.PipelineSettings, first: str, last: str,
                      rerun: str | None) -> bool:
    store = pipeline.ReceiptStore(settings.state_root)
    for stage in pipeline._stage_range(first, last, rerun):
        for task in pipeline.build_stage_tasks(settings, stage):
            if stage == rerun or pipeline.inspect_task(task, store).decision is not pipeline.Decision.REUSE:
                return True
            if stage == "run" and not pipeline._strict_coverage_for_run_task(settings, task).complete:
                return True
    return False


def run_sessions(settings: pipeline.PipelineSettings, options: SlurmSettings,
                 first: str, last: str, rerun: str | None, mode: str) -> tuple[int, dict]:
    pending = tuple(model for model in settings.models if _hardware_pending(
        replace(settings, models=(model,)), first, last, rerun))
    if not pending:
        code, summary = pipeline.run_pipeline(settings, first=first, last=last, rerun=rerun)
        return code, {"mode": mode, "allocated": False, "summary": summary}
    slots = None
    if mode == "parallel" and len(pending) > 1:
        slots = available_fpga_slots(options)
        mode = execution_mode(options, pending, slots)
        print(f"Free U55C slots: {slots}; model execution: {mode}", flush=True)
    elif len(pending) < 2:
        mode = "serial"
    groups = [pending] if mode == "serial" else [(model,) for model in pending]
    sessions = []
    with ExitStack() as stack:
        for models in groups:
            root = settings.state_root / "model_sessions" / str(uuid.uuid4())
            root.mkdir(parents=True)
            summary_path = root / "summary.json"
            payload = {"settings": _settings_payload(replace(settings, models=tuple(models))),
                       "first": first, "last": last, "rerun": rerun,
                       "summary_path": str(summary_path)}
            payload_path = root / "request.json"
            payload_path.write_text(json.dumps(payload, indent=2) + "\n")
            command = ["srun", "--nodes=1", "--ntasks=1", "--gres=fpga:u55c:1",
                       f"--partition={options.partition}", f"--cpus-per-task={options.cpus}",
                       f"--mem={options.memory}", f"--time={options.time_limit}",
                       f"--immediate={options.allocation_wait}", "--kill-on-bad-exit=1",
                       settings.python, str(settings.workspace / "workflow.py"),
                       "_model-worker", str(payload_path)]
            (root / "command.txt").write_text(shlex.join(command) + "\n")
            environment = os.environ.copy()
            environment.setdefault("CC", "/usr/bin/gcc")
            environment.setdefault("CXX", "/usr/bin/g++")
            child = stack.enter_context(pipeline.OwnedProcess.start(
                command, resources=tuple(settings.result_root(model) / ".model_session" for model in models),
                owner="model-session:" + ",".join(models), cwd=settings.workspace,
                env=environment, stdout=stack.enter_context((root / "stdout.log").open("w")),
                stderr=stack.enter_context((root / "stderr.log").open("w")), start_new_session=True))
            sessions.append((child, root, models))
            print(f"FPGA session {','.join(models)}: logs {root}", flush=True)
        while True:
            codes = [child.poll() for child, _, _ in sessions]
            if all(code is not None for code in codes):
                break
            if any(code not in (None, 0) for code in codes):
                break
            time.sleep(0.2)
        failed = any(child.returncode not in (None, 0) for child, _, _ in sessions)
        if failed:
            for child, _, _ in sessions:
                if child.poll() is None:
                    child.terminate()
        results = []
        for child, root, models in sessions:
            code = child.wait()
            summary_path = root / "summary.json"
            results.append({"models": list(models), "exit_code": code, "logs": str(root),
                            "summary": json.loads(summary_path.read_text()) if summary_path.exists() else None})
        return (1 if any(result["exit_code"] for result in results) else 0), {
            "mode": mode, "free_fpga_slots": slots, "allocated": True, "sessions": results}


def coordinate(settings: pipeline.PipelineSettings, options: SlurmSettings, *,
               first: str, last: str, rerun: str | None, inspect_only: bool) -> tuple[int, dict]:
    reject_allocation()
    selected = pipeline._stage_range(first, last, rerun)
    hardware = tuple(stage for stage in selected if stage in ("run", "refine"))
    if inspect_only:
        code, summary = pipeline.run_pipeline(settings, first=first, last=last, rerun=rerun, inspect_only=True)
        summary["model_execution"] = options.model_execution
        summary["parallel_fallback"] = options.parallel_fallback
        summary["allocation_scope"] = "model run+refine"
        return code, summary
    mode = options.model_execution
    if hardware and mode == "parallel" and len(settings.models) > 1:
        pending = []
        for model in settings.models:
            try:
                needed = _hardware_pending(replace(settings, models=(model,)), hardware[0],
                                           hardware[-1], rerun if rerun in hardware else None)
            except (OSError, ValueError):
                if "generate" not in selected:
                    raise
                needed = True  # Generation will repair missing or invalid suite indexes.
            if needed:
                pending.append(model)
        if len(pending) > 1:
            slots = available_fpga_slots(options)
            mode = execution_mode(options, tuple(pending), slots)
            print(f"Preflight free U55C slots: {slots}; model execution: {mode}", flush=True)
    summary = {"tag": settings.tag, "model_execution": mode, "stages": []}
    if "generate" in selected:
        code, result = pipeline.run_pipeline(settings, first="generate", last="generate",
                                             rerun="generate" if rerun == "generate" else None)
        summary["stages"].append(result)
        if code:
            return code, summary
    if hardware:
        code, result = run_sessions(settings, options, hardware[0], hardware[-1],
                                    rerun if rerun in hardware else None, mode)
        summary["stages"].append(result)
        summary["model_execution"] = result.get("mode", mode)
        if code:
            return code, summary
    downstream = tuple(stage for stage in selected if stage in ("compose", "prepare", "plot"))
    if downstream:
        code, result = pipeline.run_pipeline(settings, first=downstream[0], last=downstream[-1],
                                             rerun=rerun if rerun in downstream else None)
        summary["stages"].append(result)
        return code, summary
    return 0, summary
