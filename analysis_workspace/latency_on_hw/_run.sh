#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <llama2|llama3|llama3p2_1b|llama3p2_3b> [prefill|decode|generation|all]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
case_filter="app=eladd | app=eladd_layout_fused"

filter_args=()
if [[ -n "${case_filter//[[:space:]]/}" ]]; then
  filter_args+=(--filter "${case_filter}")
fi

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
    input_dir="generated_suites/llama2_7b_main_full.new_c4"
    output_dir="outputs_llama2_main.new_c4"
    fpga_bins="C4_2"
    ;;
  llama3)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3"
    input_dir="generated_suites/llama3_8b_main_full.new_c4"
    output_dir="outputs_llama3_main.new_c4"
    fpga_bins="C4_2"
    ;;
  llama3p2_1b)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3p2_1b"
    input_dir="generated_suites/llama3p2_1b_main"
    output_dir="outputs_llama3p2_1b_main"
    fpga_bins="C4_2"
    ;;
  llama3p2_3b)
    build_dir="${SCRIPT_DIR}/../../build_latency_llama3p2_3b"
    input_dir="generated_suites/llama3p2_3b_main"
    output_dir="outputs_llama3p2_3b_main"
    fpga_bins="C4_2"
    ;;
  *)
    echo "Error: unsupported model: ${model}" >&2
    exit 1
    ;;
esac

FPGA_BINS="${fpga_bins}" \
STAGES="${stages}" \
BUILD_DIR="${build_dir}" \
SKIP_EXISTING=0 \
BLACKBOX_TIMEOUT=24h ./run_hw.sh \
    --input "${input_dir}" \
    --output "${output_dir}" \
    --power-kernel-iterations=auto \
    --power-target-sec=10 \
    --power-latency-interval=0.1 \
    --no-power-auto-duration \
    "${filter_args[@]}" \
    --retry \
    | tee -i "logs/main_${model}_new_c4_hadamard_${log_stage}.log"

# 정확히 하나의 kernel app                                                                                                                                                                                                             
#--filter 'app=softmax_layout_fused'                                                                                                                                                                                                    
                                                                                                                                                                                                                                      
# 여러 kernel 중 하나                                                                                                                                                                                                                  
#--filter 'app=softmax_layout_fused | app=softmax'                                                                                                                                                                                      
                                                                                                                                                                                                                                      
# glob 패턴                                                                                                                                                                                                                            
#--filter 'app=~softmax*'                                                                                                                                                                                                               
                                                                                                                                                                                                                                      
# kernel과 stage를 동시에 제한                                                                                                                                                                                                         
#--filter 'app=softmax_layout_fused & stage=generation'

# 여러 --filter는 AND로 결합
#--filter 'app=softmax_layout_fused' --filter 'stage=generation'
