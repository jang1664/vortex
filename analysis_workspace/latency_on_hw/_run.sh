#!/bin/bash

SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align ./run_hw.sh \
    --input generated_suites/main \
    --output outputs_temp \
    --retry \
    --retry-timeout-growth 2 \
    --filter "app=softmax_layout_fused | app=softmax" \
    | tee -i logs/main.log

SKIP_EXISTING=1 ./run_hw.sh --input generated_suites/main_power --output outputs_main_power \
  --no-latency --retry --retry-timeout-growth 2 \
  --power-auto-duration --power-max-iterations 3 \
  | tee -i logs/main_power.log

# --filter \ "app!=sgemm_tcu" \