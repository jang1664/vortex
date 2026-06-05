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
RELATIVE_SCOPE="${RELATIVE_SCOPE:-global}"
SHARE_Y="${SHARE_Y:-0}"
LEGEND_POSITION="${LEGEND_POSITION:-right}"
LEGEND_NCOL="${LEGEND_NCOL:-}"
FIGURE_TITLE="${FIGURE_TITLE:-}"
X_LABEL="${X_LABEL:-}"
Y_LABEL="${Y_LABEL:-}"
LEGEND_TITLE="${LEGEND_TITLE:-}"

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
  --relative-scope "${RELATIVE_SCOPE}"
  --legend-position "${LEGEND_POSITION}"
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

if [[ -n "${LEGEND_NCOL}" ]]; then
  cmd+=(--legend-ncol "${LEGEND_NCOL}")
fi

if [[ -n "${FIGURE_TITLE}" ]]; then
  cmd+=(--figure-title "${FIGURE_TITLE}")
fi

if [[ -n "${X_LABEL}" ]]; then
  cmd+=(--x-label "${X_LABEL}")
fi

if [[ -n "${Y_LABEL}" ]]; then
  cmd+=(--y-label "${Y_LABEL}")
fi

if [[ -n "${LEGEND_TITLE}" ]]; then
  cmd+=(--legend-title "${LEGEND_TITLE}")
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi
cmd+=("$@")

printf '+'
printf ' %q' "${cmd[@]}"
printf '\n'
exec "${cmd[@]}"
