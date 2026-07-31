#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
mkdir -p logs

case_filter="(app=softmax | app=softmax_layout_fused) & shape.batch=1 & shape.seqq=8192 & shape.seqk=8192"
log_file="logs/rerun_llama3_C3_C4_v3_prefill_b1_s8192_softmax.log"

FPGA_BINS="C4_v3" \
STAGES="prefill" \
BUILD_DIR="${SCRIPT_DIR}/../../build_latency_llama3" \
SKIP_EXISTING=0 \
BLACKBOX_TIMEOUT=24h \
./run_hw.sh \
    --input generated_suites/llama3_8b_main_full_v2.C3_C4_v3 \
    --output outputs_llama3_main.C3_C4_v3 \
    --filter "${case_filter}" \
    --power-kernel-iterations=auto \
    --power-target-sec=10 \
    --power-latency-interval=0.1 \
    --no-power-auto-duration \
    --retry \
    "$@" \
    | tee -i "${log_file}"
