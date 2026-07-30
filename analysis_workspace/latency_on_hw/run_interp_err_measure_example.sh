#!/bin/bash

# Reference command: measure a random sample of interpolated Llama2 or Llama3
# C4 decode cases, report interpolation error, and promote every successful
# measurement into the model's main C4 raw_db.csv.
#
# Usage:
#   ./run_interp_err_measure_example.sh llama2
#   ./run_interp_err_measure_example.sh llama3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${HOME}/.conda/envs/vortex/bin/python"

cd "${REPO_ROOT}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <llama2|llama3>" >&2
  exit 1
fi

MODEL="$1"

if [[ "${MODEL}" == "llama2" ]]; then
  SUITE="${SCRIPT_DIR}/generated_suites/llama2_7b_main_full/generation_merged/generation_merged_C4.yaml"
  OUTPUT_ROOT="${SCRIPT_DIR}/outputs_llama2_main/C4"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama2"
elif [[ "${MODEL}" == "llama3" ]]; then
  SUITE="${SCRIPT_DIR}/generated_suites/llama3_8b_main_full/generation_merged/generation_merged_C4.yaml"
  OUTPUT_ROOT="${SCRIPT_DIR}/outputs_llama3_main/C4"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama3"
else
  echo "Error: unsupported model: ${MODEL}; expected llama2 or llama3" >&2
  exit 1
fi

MEASURE_COMMAND="env STAGE=generation SUITE={suite} OUT_DIR={out} BUILD_DIR=${BUILD_DIR} SKIP_EXISTING=0 BLACKBOX_TIMEOUT=24h ${SCRIPT_DIR}/run_fpga_bin.sh C4 --no-power --retry"

echo "[evaluate] model=${MODEL} stage=generation fpga_bin=C4"
echo "[evaluate] suite=${SUITE}"
echo "[evaluate] output_root=${OUTPUT_ROOT}"

"${PYTHON_BIN}" -m tools.latency_bench evaluate-interpolation \
  --suite "${SUITE}" \
  --output-root "${OUTPUT_ROOT}" \
  --measure-command "${MEASURE_COMMAND}" \
  --metric fpga_cycle \
  --samples-per-kernel 5 \
  --seed 0

# --evaluation-id "${MODEL}_decode_c4_fpga_cycle"
