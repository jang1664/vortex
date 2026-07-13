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
BLACKBOX_TIMEOUT=1h ./run_hw.sh \
    --input generated_suites/llama2_7b_main \
    --output outputs_llama2_main \
    --power-kernel-iterations=auto \
    --no-power-auto-duration \
    --retry \
    | tee -i logs/main.log

BLACKBOX_TIMEOUT=1h ./run_hw.sh \
    --input generated_suites/llama3_8b_main \
    --output outputs_llama3_main \
    --power-kernel-iterations=auto \
    --no-power-auto-duration \
    --retry \
    | tee -i logs/main.log