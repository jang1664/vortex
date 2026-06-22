#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi

# Default example:
#   ./plot_results.sh
#
# Typical real run:
#   SUITES="suites/main/llama2_7b_prefill_C1.yaml suites/main/llama2_7b_prefill_C2.yaml suites/main/llama2_7b_prefill_C3.yaml" \
#   RAW_DBS="outputs/naive_simd/raw_db.csv outputs/naive_gemm_tcol32/raw_db.csv outputs/improve_tcol32/raw_db.csv" \
#   OUT_DIR=figures/prefill_variants \
#   ./plot_results.sh
#
# Axis controls:
#   X_AXIS=seq_len HUE_AXIS=variant ROW_AXIS=stage COL_AXIS=batch ./plot_results.sh
#   HUE_AXIS=none ROW_AXIS=batch COL_AXIS=stage ./plot_results.sh
#   STACK_BY=kind ./plot_results.sh
#   SHARE_Y=1 ./plot_results.sh
#   RELATIVE_SCOPE=x_tick LEGEND_POSITION=right ./plot_results.sh
#   X_TICK_LABEL_MODE=bar X_TICK_LABEL_ROTATION=25 X_TICK_LABEL_HA=right ./plot_results.sh
#   GROUPED_BAR_GAP=0.06 VALUE_LABEL_ROTATION=90 VALUE_LABEL_FONTSIZE=6 ./plot_results.sh
#
# Measurement controls:
#   METRIC=p50_us SELECT=median MISSING=nan ./plot_results.sh
#   METRIC=avg_us SELECT=latest MISSING=error ./plot_results.sh
#
# Extra latency_bench visualize args can be appended after "--":
#   ./plot_results.sh -- --fpga-bin-label naive_simd
#   ./plot_results.sh -- --value-order variant=all_sgemm_tcu_spinquant,attn_sgemm_tcu_fpint_gemm_naive_spinquant,all_fpint_gemm_naive_spinquant

SUITES="${SUITES:-suites/main/llama2_7b_prefill_C1.yaml suites/main/llama2_7b_prefill_C2.yaml suites/main/llama2_7b_prefill_C3.yaml suites/main/llama2_7b_prefill_C4_alone.yaml suites/main/llama2_7b_prefill_C4_fused.yaml suites/main/llama2_7b_generation_C1.yaml suites/main/llama2_7b_generation_C2.yaml suites/main/llama2_7b_generation_C3.yaml suites/main/llama2_7b_generation_C4_alone.yaml suites/main/llama2_7b_generation_C4_fused.yaml}"
RAW_DBS="${RAW_DBS:-outputs/naive_simd/raw_db.csv outputs/naive_gemm_tcol32/raw_db.csv outputs/improve_tcol32/raw_db.csv}"
OUT_DIR="${OUT_DIR:-outputs/figures}"

METRIC="${METRIC:-p50_us}"
SELECT="${SELECT:-latest}"
MISSING="${MISSING:-error}"

X_AXIS="${X_AXIS:-seq_len}"
HUE_AXIS="${HUE_AXIS:-variant}"
ROW_AXIS="${ROW_AXIS:-stage}"
COL_AXIS="${COL_AXIS:-batch}"
STACKED="${STACKED:-1}"
STACK_BY="${STACK_BY:-name}"
VALUE_LABELS="${VALUE_LABELS:-1}"
VALUE_LABEL_ROTATION="${VALUE_LABEL_ROTATION:-0}"
VALUE_LABEL_FONTSIZE="${VALUE_LABEL_FONTSIZE:-7}"
GROUPED_BAR_GAP="${GROUPED_BAR_GAP:-0.04}"
X_TICK_LABEL_MODE="${X_TICK_LABEL_MODE:-group}"
X_TICK_LABEL_ROTATION="${X_TICK_LABEL_ROTATION:-0}"
X_TICK_LABEL_HA="${X_TICK_LABEL_HA:-center}"
RELATIVE="${RELATIVE:-1}"
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
  --value-label-rotation "${VALUE_LABEL_ROTATION}"
  --value-label-fontsize "${VALUE_LABEL_FONTSIZE}"
  --grouped-bar-gap "${GROUPED_BAR_GAP}"
  --x-tick-label-mode "${X_TICK_LABEL_MODE}"
  --x-tick-label-rotation "${X_TICK_LABEL_ROTATION}"
  --x-tick-label-ha "${X_TICK_LABEL_HA}"
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

for suite in ${SUITES}; do
  cmd+=(--suite "${suite}")
done

for raw_db in ${RAW_DBS}; do
  cmd+=(--raw-db "${raw_db}")
done

if [[ "${1:-}" == "--" ]]; then
  shift
fi
cmd+=("$@")

printf '+'
printf ' %q' "${cmd[@]}"
printf '\n'
exec "${cmd[@]}"
