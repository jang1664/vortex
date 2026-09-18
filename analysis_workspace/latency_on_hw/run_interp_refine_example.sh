#!/bin/bash

# Reference command: resume latency-only decode interpolation from the current
# experiment's merged-suite index. The index selects the trusted local PKL for
# each physical FPGA alias; the stable refinement ID resumes its checkpoint.
#
# Usage:
#   ./run_interp_refine_example.sh llama2
#   ./run_interp_refine_example.sh llama3

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

C3_NAME=C3
EXPERIMENT_TAG="${EXPERIMENT_TAG:-th16_20260917}"
SUITE_SIZE="${SUITE_SIZE:-full}"

FPGA_BINS=(C1 ${C3_NAME} C4)

if [[ "${MODEL}" == "llama2" ]]; then
  SUITE_NAME="llama2_7b_main_${SUITE_SIZE}.${EXPERIMENT_TAG}"
  OUT_NAME="outputs_llama2_main.${EXPERIMENT_TAG}"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama2"
elif [[ "${MODEL}" == "llama3" ]]; then
  SUITE_NAME="llama3_8b_main_${SUITE_SIZE}.${EXPERIMENT_TAG}"
  OUT_NAME="outputs_llama3_main.${EXPERIMENT_TAG}"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama3"
else
  echo "Error: unsupported model: ${MODEL}; expected llama2 or llama3" >&2
  exit 1
fi

for FPGA_BIN in "${FPGA_BINS[@]}"; do
  INPUT_DIR="${SCRIPT_DIR}/generated_suites/${SUITE_NAME}"
  SUITE="$("${PYTHON_BIN}" "${SCRIPT_DIR}/workflow.py" suite \
    --input "${INPUT_DIR}" --stage generation --label "${FPGA_BIN}")"
  OUTPUT_ROOT="${SCRIPT_DIR}/${OUT_NAME}/${FPGA_BIN}"
  MEASURE_COMMAND="env STAGE=generation SUITE={suite} OUT_DIR={out} BUILD_DIR=${BUILD_DIR} SKIP_EXISTING=1 BLACKBOX_TIMEOUT=24h ${SCRIPT_DIR}/run_fpga_bin.sh ${FPGA_BIN} --latency --no-power --retry"

  REFINE_ARGS=(
    --suite "${SUITE}"
    --output-root "${OUTPUT_ROOT}"
    --refinement-id "${EXPERIMENT_TAG}.${MODEL}.${FPGA_BIN}.latency"
    --measure-command "${MEASURE_COMMAND}"
    --metric fpga_cycle
    --target-error 0.05
    --validation-samples 3
    --max-iterations 3
    --sampling-strategy midpoint
    --seed 0
  )
  if [[ -n "${KERNEL_TYPE_FILTER:-}" ]]; then
    REFINE_ARGS+=(--kernel-type "${KERNEL_TYPE_FILTER}")
  fi

  echo "[refine] model=${MODEL} stage=generation fpga_bin=${FPGA_BIN}"
  echo "[refine] suite=${SUITE}"
  echo "[refine] output_root=${OUTPUT_ROOT}"
  echo "[refine] experiment_tag=${EXPERIMENT_TAG} kernel_type_filter=${KERNEL_TYPE_FILTER:-<all>}"

  "${PYTHON_BIN}" -m tools.latency_bench refine-interpolation \
    "${REFINE_ARGS[@]}"
done
