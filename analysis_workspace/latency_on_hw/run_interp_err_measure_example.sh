#!/bin/bash

# Reference command: measure a random sample of interpolated Llama2 C4 decode
# cases, report interpolation error, and promote every successful measurement
# into outputs_llama2_main/C4/raw_db.csv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${HOME}/.conda/envs/vortex/bin/python"

cd "${REPO_ROOT}"

SUITE="${SCRIPT_DIR}/generated_suites/llama2_7b_main/generation_merged/generation_merged_C4.yaml"
OUTPUT_ROOT="${SCRIPT_DIR}/outputs_llama2_main/C4"
BUILD_DIR="${REPO_ROOT}/build_latency_llama2"

MEASURE_COMMAND="env STAGE=generation SUITE={suite} OUT_DIR={out} BUILD_DIR=${BUILD_DIR} SKIP_EXISTING=0 BLACKBOX_TIMEOUT=24h ${SCRIPT_DIR}/run_fpga_bin.sh C4 --no-power --retry"

"${PYTHON_BIN}" -m tools.latency_bench evaluate-interpolation \
  --suite "${SUITE}" \
  --output-root "${OUTPUT_ROOT}" \
  --measure-command "${MEASURE_COMMAND}" \
  --metric fpga_cycle \
  --samples-per-kernel 5 \
  --seed 0 \
  --evaluation-id example
