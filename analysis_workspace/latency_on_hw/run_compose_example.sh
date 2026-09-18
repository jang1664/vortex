#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
tag="${EXPERIMENT_TAG:-th16_20260917}"
size="${SUITE_SIZE:-full}"
"${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}" run_compose.py \
  --llama2-results "outputs_llama2_main.${tag}" \
  --llama3-results "outputs_llama3_main.${tag}" \
  --llama2-suites "generated_suites/llama2_7b_main_${size}.${tag}" \
  --llama3-suites "generated_suites/llama3_8b_main_${size}.${tag}" \
  --models llama2_7b,llama3_8b --metric fpga_cycle_latency \
  --select latest --missing error --out "composed_results.${tag}" "$@"
