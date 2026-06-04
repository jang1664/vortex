#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi

OUT_DIR="${OUT_DIR:-outputs_sample/figures}"
METRIC="${METRIC:-p50_us}"
SELECT="${SELECT:-median}"
MISSING="${MISSING:-nan}"

X_AXIS="${X_AXIS:-seq_len}"
HUE_AXIS="${HUE_AXIS:-variant}"
ROW_AXIS="${ROW_AXIS:-stage}"
COL_AXIS="${COL_AXIS:-batch}"
STACKED="${STACKED:-1}"
STACK_BY="${STACK_BY:-name}"
VALUE_LABELS="${VALUE_LABELS:-1}"
RELATIVE="${RELATIVE:-0}"
SHARE_Y="${SHARE_Y:-0}"

cmd=(
  "${PYTHON_BIN}" -m tools.latency_bench visualize
  --suite suites_sample/llama2_7b_prefill_plot_sample.yaml
  --suite suites_sample/llama2_7b_generation_plot_sample.yaml
  --raw-db outputs_sample/raw_db.csv
  --out "${OUT_DIR}"
  --metric "${METRIC}"
  --select "${SELECT}"
  --missing "${MISSING}"
  --x "${X_AXIS}"
  --hue "${HUE_AXIS}"
  --row "${ROW_AXIS}"
  --col "${COL_AXIS}"
  --stack-by "${STACK_BY}"
  --relative
)

if [[ "${STACKED}" == "0" ]]; then
  cmd+=(--no-stacked)
fi

if [[ "${VALUE_LABELS}" == "0" ]]; then
  cmd+=(--no-value-labels)
fi

if [[ "${RELATIVE}" != "0" ]]; then
  cmd+=(--relative)
fi

if [[ "${SHARE_Y}" != "0" ]]; then
  cmd+=(--share-y)
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi
cmd+=("$@")

printf '+'
printf ' %q' "${cmd[@]}"
printf '\n'
exec "${cmd[@]}"
