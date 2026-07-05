#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${PYTHON:-python3}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
SHAPE_REGEX="${SHAPE_REGEX:-.*}"
GENERATED_ROOT="${GENERATED_ROOT:-power_measure_suites_generated}"
OUT_ROOT="${OUT_ROOT:-power_measure_suites_outputs}"
POWER_AUTO_DURATION="${POWER_AUTO_DURATION:-off}"
POWER_MEASURE_LATENCY="${POWER_MEASURE_LATENCY:-on}"
POWER_ITERATIONS="${POWER_ITERATIONS:-1}"

POWER_MODE_ARGS=(--power-iterations "${POWER_ITERATIONS}")
case "${POWER_AUTO_DURATION}" in
  1|on|true|yes)
    POWER_MODE_ARGS+=(--power-auto-duration)
    ;;
  0|off|false|no)
    POWER_MODE_ARGS+=(--no-power-auto-duration)
    ;;
  *)
    echo "ERROR: POWER_AUTO_DURATION must be on or off, got: ${POWER_AUTO_DURATION}" >&2
    exit 1
    ;;
esac

case "${POWER_MEASURE_LATENCY}" in
  1|on|true|yes)
    POWER_MODE_ARGS+=(--power-measure-latency)
    ;;
  0|off|false|no)
    POWER_MODE_ARGS+=(--no-power-measure-latency)
    ;;
  *)
    echo "ERROR: POWER_MEASURE_LATENCY must be on or off, got: ${POWER_MEASURE_LATENCY}" >&2
    exit 1
    ;;
esac

COMMON_ARGS=(
  --run-id "${RUN_ID}"
  --shape-regex "${SHAPE_REGEX}"
  --retry
  --generated-root "${GENERATED_ROOT}"
  --out "${OUT_ROOT}"
  "${POWER_MODE_ARGS[@]}"
)

"${PYTHON_BIN}" measure_power.py \
  --fpga-bin naive_simd \
  --app-regex '^(sgemm_tcu|rmsnorm|rms_norm_layout_fused|rope|rope_layout_fused|silu|silu_layout_fused|eladd|eladd_layout_fused|elmul|elmul_layout_fused|tile_input_a|detile_output|kv_cache_quant_w4a16|kv_cache_quant_layout_fused_w4a16|tile_weight_w4a16|tile_scale_zp_w4a16|head_concat|head_concat_layout_fused)$' \
  "${COMMON_ARGS[@]}"

"${PYTHON_BIN}" measure_power.py \
  --fpga-bin improve_no_tcu_lut_fexp \
  --app-regex '^(softmax|softmax_layout_fused)$' \
  "${COMMON_ARGS[@]}"

"${PYTHON_BIN}" measure_power.py \
  --fpga-bin naive_gemm_tcol32 \
  --app-regex '^fpint_gemm_ffn_hw_naive$' \
  "${COMMON_ARGS[@]}"

"${PYTHON_BIN}" measure_power.py \
  --fpga-bin improve_tcol32 \
  --app-regex '^fpint_gemm_ffn_hw$' \
  "${COMMON_ARGS[@]}"
