#!/usr/bin/env python3
"""Record the legacy and successor Slurm jobs once per hour."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TERMINAL_STATES = {
    "BOOT_FAIL",
    "CANCELLED",
    "COMPLETED",
    "DEADLINE",
    "FAILED",
    "NODE_FAIL",
    "OUT_OF_MEMORY",
    "PREEMPTED",
    "REVOKED",
    "TIMEOUT",
}


def _run(*command: str) -> str:
    return subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _job_status(job_id: str) -> dict[str, Any]:
    queued = _run(
        "squeue", "-j", job_id, "-h", "-o", "%i|%T|%M|%l|%R"
    )
    if queued:
        fields = queued.splitlines()[0].split("|", 4)
        if len(fields) == 5:
            return {
                "job_id": fields[0],
                "state": fields[1],
                "elapsed": fields[2],
                "limit": fields[3],
                "reason_or_node": fields[4],
                "source": "squeue",
                "terminal": False,
            }

    accounting = _run(
        "sacct", "-X", "-j", job_id,
        "--format=JobIDRaw,State,ExitCode,Elapsed,End", "-n", "-P",
    )
    for line in accounting.splitlines():
        fields = line.split("|", 4)
        if len(fields) != 5 or fields[0] != job_id:
            continue
        state = fields[1].split()[0].split("+")[0]
        return {
            "job_id": job_id,
            "state": state,
            "exit_code": fields[2],
            "elapsed": fields[3],
            "end": fields[4],
            "source": "sacct",
            "terminal": state in TERMINAL_STATES,
        }
    return {
        "job_id": job_id,
        "state": "UNKNOWN",
        "source": "unavailable",
        "terminal": False,
    }


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--legacy-job", required=True)
    parser.add_argument("--successor-job", required=True)
    parser.add_argument("--interval", type=int, default=3600)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--campaign-status", type=Path, required=True)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.interval < 60:
        parser.error("--interval must be at least 60 seconds")

    lock_path = args.status.with_suffix(args.status.suffix + ".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0

        while True:
            checked_at = datetime.now(timezone.utc).isoformat()
            legacy = _job_status(args.legacy_job)
            successor = _job_status(args.successor_job)
            try:
                campaign = json.loads(args.campaign_status.read_text())
            except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
                campaign = None
            payload = {
                "type": "vortex-latency-slurm-monitor",
                "schema_version": 1,
                "checked_at_utc": checked_at,
                "interval_seconds": args.interval,
                "legacy": legacy,
                "successor": successor,
                "campaign_status": campaign,
            }
            _atomic_json(args.status, payload)
            args.log.parent.mkdir(parents=True, exist_ok=True)
            with args.log.open("a", encoding="utf-8") as output:
                output.write(
                    f"{checked_at} legacy={legacy['job_id']}:{legacy['state']} "
                    f"successor={successor['job_id']}:{successor['state']}\n"
                )
            if args.once or successor["terminal"]:
                return 0
            time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
