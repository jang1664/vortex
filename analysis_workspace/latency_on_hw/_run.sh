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
SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=1h ./run_hw.sh \
    --input generated_suites/llama2_7b_main \
    --output outputs_main_small_test \
    --power-kernel-iterations=auto \
    --no-power-auto-duration \
    --retry \
    | tee -i logs/main.log

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=1h ./run_hw.sh \
#     --input generated_suites/llama3_8b_main \
#     --output outputs_main_small_test \
#     --power-kernel-iterations=auto \
#     --no-power-auto-duration \
#     --retry \
#     | tee -i logs/main.log