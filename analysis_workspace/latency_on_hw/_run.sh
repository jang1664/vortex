#!/bin/bash

set -euo pipefail

# Edit these three values when changing FPGA versions.
suite_postfix="C3_C4_v3"
output_postfix="C3_C4_v3"
fpga_bins="${FPGA_BINS:-C1 C3 C4_v3}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <llama2|llama3|llama3p2_1b|llama3p2_3b> [prefill|decode|generation|all]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
idle_stability_policy="${IDLE_STABILITY_POLICY:-${SCRIPT_DIR}/idle_stability_policy.json}"
cd "${SCRIPT_DIR}"
mkdir -p logs
# ------------------------------------------------
# options
# ------------------------------------------------
# --retry \
# --retry-timeout-growth 2 \

# --------------------------------------------------------------------------------------------------------
# latency measure examples
# --------------------------------------------------------------------------------------------------------
model="$1"
requested_stage="${2:-all}"
# case_filter="(app=hadamard_layout_fused | app=head_concat_layout_fused | app=head_concat | app=silu)"
case_filter="${CASE_FILTER:-}"
skip_existing="${SKIP_EXISTING:-1}"

case "${requested_stage}" in
  prefill)
    stages="prefill"
    log_stage="prefill"
    ;;
  decode|generation)
    stages="generation"
    log_stage="decode"
    ;;
  all)
    stages="prefill generation"
    log_stage="all"
    ;;
  *)
    echo "Error: unsupported stage: ${requested_stage}; expected prefill, decode, generation, or all" >&2
    exit 1
    ;;
esac

case "${model}" in
  llama2)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama2"
    input_dir="generated_suites/llama2_7b_main_full_v2.${suite_postfix}"
    output_dir="outputs_llama2_main.${output_postfix}.run2"
    ;;
  llama3)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3"
    input_dir="generated_suites/llama3_8b_main_full_v2.${suite_postfix}"
    output_dir="outputs_llama3_main.${output_postfix}.run2"
    ;;
  llama3p2_1b)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3p2_1b"
    input_dir="generated_suites/llama3p2_1b_main"
    output_dir="outputs_llama3p2_1b_main"
    ;;
  llama3p2_3b)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3p2_3b"
    input_dir="generated_suites/llama3p2_3b_main"
    output_dir="outputs_llama3p2_3b_main"
    ;;
  *)
    echo "Error: unsupported model: ${model}" >&2
    exit 1
    ;;
esac

if [[ "${RERUN_UNSTABLE_POWER:-0}" == "1" ]]; then
  if [[ "${fpga_bins}" == *" "* ]]; then
    echo "Error: RERUN_UNSTABLE_POWER=1 requires exactly one FPGA_BINS label" >&2
    exit 1
  fi

  raw_db="${output_dir}/${fpga_bins}/raw_db.csv"
  idle_std_threshold="${IDLE_STD_THRESHOLD_W:-0.30}"
  case_filter="$({ python3 - "${raw_db}" "${idle_std_threshold}" <<'PY'
import csv
import json
import sys
from pathlib import Path

raw_db = Path(sys.argv[1])
threshold = float(sys.argv[2])
if not raw_db.is_file():
    raise SystemExit(f"missing raw DB: {raw_db}")

latest_rows = {}
with raw_db.open(newline="") as source:
    for row in csv.DictReader(source):
        if row.get("status") == "pass":
            latest_rows[(row.get("app", ""), row.get("args", ""))] = row

cases = set()
for key, row in latest_rows.items():
    try:
        idle_std_w = float(row.get("power_idle_std_w", ""))
    except ValueError:
        continue
    if idle_std_w > threshold:
        cases.add(key)

terms = [
    f"(app={json.dumps(app)} & args={json.dumps(args)})"
    for app, args in sorted(cases)
]
if not terms:
    raise SystemExit(
        f"no passing rows exceed idle_std threshold {threshold:.3f} W in {raw_db}"
    )
print(" | ".join(terms))
PY
  } 2>&1)" || {
    echo "Error: failed to build unstable-power case filter: ${case_filter}" >&2
    exit 1
  }
  skip_existing=0
  echo "Rerunning unstable power cases: model=${model} fpga_bin=${fpga_bins} threshold=${idle_std_threshold}W"
fi

filter_args=()
if [[ -n "${case_filter//[[:space:]]/}" ]]; then
  filter_args+=(--filter "${case_filter}")
fi

FPGA_BINS="${fpga_bins}" \
STAGES="${stages}" \
BUILD_DIR="${build_dir}" \
SKIP_EXISTING="${skip_existing}" \
BLACKBOX_TIMEOUT=24h ./run_hw.sh \
    --input "${input_dir}" \
    --output "${output_dir}" \
    --power-kernel-iterations=auto \
    --power-target-sec=10 \
    --power-latency-interval=0.1 \
    --power-idle-stability-policy "${idle_stability_policy}" \
    --no-power-auto-duration \
    "${filter_args[@]}" \
    --retry \
    | tee -i "logs/main_${model}_${output_postfix}_hadamard_${log_stage}.log"
