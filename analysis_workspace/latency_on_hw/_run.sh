#!/bin/bash
target=$1
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
fi