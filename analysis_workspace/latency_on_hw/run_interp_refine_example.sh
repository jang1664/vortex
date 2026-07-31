#!/bin/bash

# Reference command: refine Llama2 or Llama3 decode interpolation for all
# kernel types on C1, C3, and C4_2 until the target error is reached or three
# iterations are exhausted. Every successfully measured validation case is
# promoted into the main raw DB.
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
C4_NAME=C4_v3

LLAMA2_SUITE_NAME=llama2_7b_main_full_v2.${C3_NAME}_${C4_NAME}
LLAMA2_OUT_NAME=outputs_llama2_main.${C3_NAME}_${C4_NAME}
LLAMA2_KERNEL_TYPE_FILTER=""

LLAMA3_SUITE_NAME=llama3_8b_main_full_v2.${C3_NAME}_${C4_NAME}
LLAMA3_OUT_NAME=outputs_llama3_main.${C3_NAME}_${C4_NAME}
LLAMA3_KERNEL_TYPE_FILTER=""

FPGA_BINS=(C1 ${C3_NAME} ${C4_NAME})

if [[ "${MODEL}" == "llama2" ]]; then
  SUITE_NAME="${LLAMA2_SUITE_NAME}"
  OUT_NAME="${LLAMA2_OUT_NAME}"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama2"
  KERNEL_TYPE_FILTER="${LLAMA2_KERNEL_TYPE_FILTER}"
elif [[ "${MODEL}" == "llama3" ]]; then
  SUITE_NAME="${LLAMA3_SUITE_NAME}"
  OUT_NAME="${LLAMA3_OUT_NAME}"
  BUILD_DIR="${REPO_ROOT}/build_latency_llama3"
  KERNEL_TYPE_FILTER="${LLAMA3_KERNEL_TYPE_FILTER}"
else
  echo "Error: unsupported model: ${MODEL}; expected llama2 or llama3" >&2
  exit 1
fi

for FPGA_BIN in "${FPGA_BINS[@]}"; do
  SUITE="${SCRIPT_DIR}/generated_suites/${SUITE_NAME}/generation_merged/generation_merged_${FPGA_BIN}.yaml"
  OUTPUT_ROOT="${SCRIPT_DIR}/${OUT_NAME}/${FPGA_BIN}"
  MEASURE_COMMAND="env STAGE=generation SUITE={suite} OUT_DIR={out} BUILD_DIR=${BUILD_DIR} SKIP_EXISTING=0 BLACKBOX_TIMEOUT=24h ${SCRIPT_DIR}/run_fpga_bin.sh ${FPGA_BIN} --no-power --retry"

  REFINE_ARGS=(
    --suite "${SUITE}"
    --output-root "${OUTPUT_ROOT}"
    --measure-command "${MEASURE_COMMAND}"
    --metric fpga_cycle
    --target-error 0.05
    --validation-samples 3
    --max-iterations 3
    --sampling-strategy midpoint
    --seed 0
  )
  if [[ -n "${KERNEL_TYPE_FILTER}" ]]; then
    REFINE_ARGS+=(--kernel-type "${KERNEL_TYPE_FILTER}")
  fi

  echo "[refine] model=${MODEL} stage=generation fpga_bin=${FPGA_BIN}"
  echo "[refine] suite=${SUITE}"
  echo "[refine] output_root=${OUTPUT_ROOT}"
  echo "[refine] kernel_type_filter=${KERNEL_TYPE_FILTER:-<all>}"

  "${PYTHON_BIN}" -m tools.latency_bench refine-interpolation \
    "${REFINE_ARGS[@]}"
done
