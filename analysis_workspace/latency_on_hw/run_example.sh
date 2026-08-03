#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON:-/opt/anaconda3/bin/python}"
RUN_TAG="C3_C4_v3.run2"

cd "${SCRIPT_DIR}"

# ----------------------------------------------------------
# compose
# ----------------------------------------------------------
"${PYTHON_BIN}" run_compose.py \
  --llama2-results "outputs_llama2_main.${RUN_TAG}" \
  --llama3-results "outputs_llama3_main.${RUN_TAG}" \
  --llama2-suites generated_suites/llama2_7b_main_full_v2.C3_C4_v3 \
  --llama3-suites generated_suites/llama3_8b_main_full_v2.C3_C4_v3 \
  --raw-db-subdirs C1,C3,C4_v3 \
  --out "composed_results.${RUN_TAG}"

# ----------------------------------------------------------
# prepare
# ----------------------------------------------------------
"${PYTHON_BIN}" prepare.py \
  --composed-csv "composed_results.${RUN_TAG}/combined/composed.csv" \
  --out-tokens 128 \
  --workers 4 \
  --output-root "figure_prepare.${RUN_TAG}"

# ----------------------------------------------------------
# plot
# ----------------------------------------------------------
"${PYTHON_BIN}" plot.py \
  --plot all --out-tokens 128 --workers 4 \
  --prepared-root "figure_prepare.${RUN_TAG}" \
  --out-dir "figure_output.${RUN_TAG}"
