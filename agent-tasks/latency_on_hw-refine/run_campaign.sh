#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
  REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
TASK_DIR="${REPO_ROOT}/agent-tasks/latency_on_hw-refine"
cd "${REPO_ROOT}/analysis_workspace/latency_on_hw"
export EXPERIMENT_TAG="${EXPERIMENT_TAG:-th16_20260917}"
export PYTHON="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
export CC=/usr/bin/gcc
export CXX=/usr/bin/g++
export SUITE_SIZE="${SUITE_SIZE:-full}"
phase=starting

write_status() {
  "${PYTHON}" - "${TASK_DIR}/campaign_status.json" "$1" "$2" "${phase}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

path, state, code, phase = sys.argv[1:]
Path(path).write_text(json.dumps({
    "state": state, "phase": phase, "exit_code": int(code),
    "job_id": os.environ.get("SLURM_JOB_ID", ""),
    "experiment_tag": os.environ["EXPERIMENT_TAG"],
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
}, indent=2) + "\n")
PY
}

on_exit() {
  local code=$?
  if [[ ${code} -eq 0 ]]; then write_status complete 0; else write_status failed "${code}"; fi
}
trap on_exit EXIT

phase=pipeline
write_status running 0
"${PYTHON}" workflow.py pipeline \
  --tag "${EXPERIMENT_TAG}" \
  --suite-size "${SUITE_SIZE}" \
  "$@"
