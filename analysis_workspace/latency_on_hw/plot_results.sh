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
#   SUITES="generated_suites/prefill_merged/prefill_merged_naive_simd.yaml generated_suites/prefill_merged/prefill_merged_naive_gemm_tcol32.yaml generated_suites/prefill_merged/prefill_merged_improve_tcol32.yaml" \
#   RAW_DBS="outputs/naive_simd/raw_db.csv outputs/naive_gemm_tcol32/raw_db.csv outputs/improve_tcol32/raw_db.csv" \
#   OUT_DIR=figures/prefill_variants \
#   ./plot_results.sh
#
# Axis controls:
#   X_AXIS=seq_len HUE_AXIS=variant ROW_AXIS=stage COL_AXIS=batch ./plot_results.sh
#   HUE_AXIS=none ROW_AXIS=batch COL_AXIS=stage ./plot_results.sh
#   STACK_BY=kind ./plot_results.sh
#   SHARE_Y=1 ./plot_results.sh
#
# Measurement controls:
#   METRIC=p50_us SELECT=median MISSING=nan ./plot_results.sh
#   METRIC=avg_us SELECT=latest MISSING=error ./plot_results.sh
#
# Extra latency_bench visualize args can be appended after "--":
#   ./plot_results.sh -- --fpga-bin-label naive_simd

SUITES="${SUITES:-outputs_example/suite_example.yaml}"
RAW_DBS="${RAW_DBS:-outputs_example/raw_db.csv}"
OUT_DIR="${OUT_DIR:-outputs_example/figures}"

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
RELATIVE="${RELATIVE:-0}"
SHARE_Y="${SHARE_Y:-0}"

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
