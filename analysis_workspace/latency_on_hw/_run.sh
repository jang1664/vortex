#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <llama2|llama3|llama3p2_1b|llama3p2_3b>" >&2
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
model=$1
if [[ "$model" == "llama2" ]]; then
  BUILD_DIR=/home/jaeyongjang/project.local/vortex_fpint/build_latency_llama2 \
  BLACKBOX_TIMEOUT=24h ./run_hw.sh \
      --input generated_suites/llama2_7b_main \
      --output outputs_llama2_main \
      --power-kernel-iterations=auto \
      --no-power-auto-duration \
      --retry \
      | tee -i logs/main_llama2.log
elif [[ "$model" == "llama3" ]]; then
  BUILD_DIR=/home/jaeyongjang/project.local/vortex_fpint/build_latency_llama3 \
  BLACKBOX_TIMEOUT=24h ./run_hw.sh \
      --input generated_suites/llama3_8b_main \
      --output outputs_llama3_main \
      --power-kernel-iterations=auto \
      --no-power-auto-duration \
      --retry \
      | tee -i logs/main_llama3.log
elif [[ "$model" == "llama3p2_1b" ]]; then
  BUILD_DIR=/home/jaeyongjang/project.local/vortex_fpint/build_latency_llama3p2_1b \
  BLACKBOX_TIMEOUT=24h ./run_hw.sh \
      --input generated_suites/llama3p2_1b_main \
      --output outputs_llama3p2_1b_main \
      --power-kernel-iterations=auto \
      --no-power-auto-duration \
      --retry \
      | tee -i logs/main_llama3p2_1b.log
elif [[ "$model" == "llama3p2_3b" ]]; then
  BUILD_DIR=/home/jaeyongjang/project.local/vortex_fpint/build_latency_llama3p2_3b \
  BLACKBOX_TIMEOUT=24h ./run_hw.sh \
      --input generated_suites/llama3p2_3b_main \
      --output outputs_llama3p2_3b_main \
      --power-kernel-iterations=auto \
      --no-power-auto-duration \
      --retry \
      | tee -i logs/main_llama3p2_3b.log
else
  echo "Error: unsupported model: ${model}" >&2
  exit 1
fi
