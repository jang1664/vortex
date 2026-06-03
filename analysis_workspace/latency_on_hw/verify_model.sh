#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/outputs"
GEN_KERNEL_CFGS="${REPO_ROOT}/tools/workload/gen_kernel_cfgs.py"

PYTHON_BIN="${PYTHON:-python}"
MODEL="${MODEL:-llama2-7b}"
PREFILL_SEQ_LEN="${PREFILL_SEQ_LEN:-8}"
GEN_KV_LEN="${GEN_KV_LEN:-8}"
QBLK="${QBLK:-32}"

mkdir -p "${OUT_DIR}"

variant_label() {
  case "$1" in
    all_sgemm_tcu)
      echo "all_sgemm_tcu"
      ;;
    all_sgemm_tcu_spinquant)
      echo "all_sgemm_tcu_spinquant"
      ;;
    attn_sgemm_tcu_fpint_gemm_naive)
      echo "attn_sgemm_tcu_fpint_gemm_naive"
      ;;
    attn_sgemm_tcu_fpint_gemm_naive_spinquant)
      echo "attn_sgemm_tcu_fpint_gemm_naive_spinquant"
      ;;
    all_fpint_gemm_naive)
      echo "all_fpint_gemm_naive"
      ;;
    all_fpint_gemm_naive_spinquant)
      echo "all_fpint_gemm_naive_spinquant"
      ;;
    all_fpint_gemm_improve_alone_layout)
      echo "all_fpint_improve_alone"
      ;;
    all_fpint_gemm_improve_alone_layout_spinquant)
      echo "all_fpint_improve_alone_spinquant"
      ;;
    all_fpint_gemm_improve_fused_layout)
      echo "all_fpint_improve_fused"
      ;;
    all_fpint_gemm_improve_fused_layout_spinquant)
      echo "all_fpint_improve_fused_spinquant"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

emit_layout() {
  local stage="$1"
  local variant="$2"
  local label
  label="$(variant_label "${variant}")"

  local -a stage_args
  case "${stage}" in
    prefill)
      stage_args=(--prefill-seq-len "${PREFILL_SEQ_LEN}")
      ;;
    generation)
      stage_args=(--prefill-seq-len "${PREFILL_SEQ_LEN}" --gen-kv-len "${GEN_KV_LEN}")
      ;;
    *)
      echo "ERROR: unsupported stage: ${stage}" >&2
      return 1
      ;;
  esac

  "${PYTHON_BIN}" "${GEN_KERNEL_CFGS}" \
    --model "${MODEL}" \
    --stage "${stage}" \
    "${stage_args[@]}" \
    --qblk "${QBLK}" \
    --variant "${variant}" \
    --format layout \
    > "${OUT_DIR}/${stage}_${label}_cfgs.txt"
}

emit_stage() {
  local stage="$1"
  emit_layout "${stage}" all_sgemm_tcu
  emit_layout "${stage}" attn_sgemm_tcu_fpint_gemm_naive
  emit_layout "${stage}" all_fpint_gemm_naive
  emit_layout "${stage}" all_fpint_gemm_improve_alone_layout
  emit_layout "${stage}" all_fpint_gemm_improve_fused_layout
  emit_layout "${stage}" all_sgemm_tcu_spinquant
  emit_layout "${stage}" attn_sgemm_tcu_fpint_gemm_naive_spinquant
  emit_layout "${stage}" all_fpint_gemm_naive_spinquant
  emit_layout "${stage}" all_fpint_gemm_improve_alone_layout_spinquant
  emit_layout "${stage}" all_fpint_gemm_improve_fused_layout_spinquant
}

emit_stage prefill
emit_stage generation
