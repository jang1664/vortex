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

./make_cases.sh --input suites/main --output generated_suites/llama3_8b_main --model-prefix llama3_8b
SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="naive_simd" ./run_hw.sh \
    --input generated_suites/llama3_8b_main \
    --output outputs_main \
    --retry \
    --retry-timeout-growth 2 \
    --no-power \
    | tee -i logs/main.log

SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="improve_tcol32 naive_gemm_tcol32 improve_no_tcu_lut_fexp" ./run_hw.sh \
    --input generated_suites/llama3_8b_main \
    --output outputs_main \
    --retry \
    --retry-timeout-growth 2 \
    --no-power \
    | tee -i logs/main.log