#!/bin/bash
# Compatibility entry: generation now belongs to the workflow pipeline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then PYTHON_BIN=python3; fi
args=(
  pipeline --tag "${EXPERIMENT_TAG:-C3_C4_v3_pipeline}"
  --suite-size "${1:-quick}"
  --decode-measurement "${2:-${DECODE_MEASUREMENT:-sampled}}"
  --decode-sample-interval "${3:-${DECODE_SAMPLE_INTERVAL:-32}}"
  --candidate-map "${CANDIDATE_MAP:-${SCRIPT_DIR}/candidate_fpga_bins.yaml}"
  --from generate --to generate
)
if [[ -n "${CANDIDATES:-}" ]]; then args+=(--candidates "${CANDIDATES}"); fi
exec "${PYTHON_BIN}" "${SCRIPT_DIR}/workflow.py" "${args[@]}"
