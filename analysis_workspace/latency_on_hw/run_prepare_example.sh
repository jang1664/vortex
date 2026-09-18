#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
tag="${EXPERIMENT_TAG:-th16_20260917}"
python_bin="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
for model in llama2_7b llama3_8b; do
  "${python_bin}" prepare.py \
    --composed-csv "composed_results.${tag}/${model}/composed.csv" \
    --models "${model}" --workers 1 --exact-model-input \
    --out-tokens 128 --output-root "figure_prepare.${tag}" "$@"
done
