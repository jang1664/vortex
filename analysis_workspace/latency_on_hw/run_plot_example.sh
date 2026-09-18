#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
tag="${EXPERIMENT_TAG:-th16_20260917}"
python_bin="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
raw_args=()
for model in llama2 llama3; do
  for fpga_bin in C1 C3 C4; do
    raw_args+=(--kernel-raw-db "outputs_${model}_main.${tag}/${fpga_bin}/raw_db.csv")
  done
done
"${python_bin}" plot.py \
  --plot all --out-tokens 128 --workers 4 --formats png,pdf,svg \
  --prepared-root "figure_prepare.${tag}" \
  --out-dir "figure_output.${tag}" \
  --candidate-snapshot "outputs_llama2_main.${tag}/C1/latest/manifest.json" \
  "${raw_args[@]}" "$@"
