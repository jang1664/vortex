#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <fpga-bin> [prefill|generation] [latency_bench args...]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

FPGA_BIN="$1"
shift

STAGE="${STAGE:-prefill}"
if [[ $# -gt 0 && ( "$1" == "prefill" || "$1" == "generation" ) ]]; then
  STAGE="$1"
  shift
fi

case "${STAGE}" in
  prefill|generation)
    ;;
  *)
    echo "ERROR: unsupported STAGE=${STAGE}; expected prefill or generation" >&2
    exit 1
    ;;
esac

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi

WARMUP="${WARMUP:-0}"
ITERATIONS="${ITERATIONS:-1}"
THREADS="${THREADS:-32}"
BLACKBOX_TIMEOUT="${BLACKBOX_TIMEOUT:-30m}"
BUILD_DIR="${BUILD_DIR:-../../build}"
OUT_DIR="${OUT_DIR:-outputs/${FPGA_BIN}}"
SUITE="${SUITE:-generated_suites/${STAGE}_merged/${STAGE}_merged_${FPGA_BIN}.yaml}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"
NO_SRUN="${NO_SRUN:-0}"

if [[ ! -f "${SUITE}" ]]; then
  echo "ERROR: suite not found: ${SUITE}" >&2
  exit 1
fi

cmd=(
  "${PYTHON_BIN}" -m tools.latency_bench run
  --build-dir "${BUILD_DIR}"
  --fpga-bin "${FPGA_BIN}"
  --suite "${SUITE}"
  --out "${OUT_DIR}"
  --warmup "${WARMUP}"
  --iterations "${ITERATIONS}"
  "--blackbox-arg=--threads=${THREADS}"
  --blackbox-timeout "${BLACKBOX_TIMEOUT}"
)

if [[ "${SKIP_EXISTING}" != "0" ]]; then
  cmd+=(--skip-existing)
fi

if [[ "${NO_SRUN}" != "0" ]]; then
  cmd+=(--no-srun)
fi

if [[ -n "${RUN_ID:-}" ]]; then
  cmd+=(--run-id "${RUN_ID}")
fi

cmd+=("$@")

exec "${cmd[@]}"
