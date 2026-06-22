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
  --filter "app==kv_cache_quant_layout_fused_w4a16" \
  | tee -i logs/main_power.log

  # --filter \ "app==sgemm_tcu" \

./make_cases.sh --input suites/main_power_long --output generated_suites/main_power_long

STAGES=prefill SKIP_EXISTING=1 ./run_hw.sh \
  --input generated_suites/main_power_long \
  --output outputs_main_power_long \
  --no-latency --retry --retry-timeout-growth 2 \
  --power-auto-duration --power-max-iterations 1 \
  --filter "app==kv_cache_quant_layout_fused_w4a16"