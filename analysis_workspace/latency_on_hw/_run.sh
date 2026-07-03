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
# fpint gemm
if [[ "$target" == "latency" ]]; then
  SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=10m FPGA_BINS="improve_tcol32 naive_gemm_tcol32" ./run_hw.sh \
      --input generated_suites/llama2_7b_main \
      --output outputs_main_small \
      --no-power \
      --retry \
      | tee -i logs/main.log

  # others
  SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=10m FPGA_BINS="naive_simd improve_no_tcu_lut_fexp" ./run_hw.sh \
      --input generated_suites/llama2_7b_main \
      --output outputs_main_small \
      --no-power \
      --retry \
      | tee -i logs/main.log

  SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=10m FPGA_BINS="improve_tcol32 naive_gemm_tcol32" ./run_hw.sh \
      --input generated_suites/llama3_8b_main \
      --output outputs_main_small \
      --no-power \
      --retry \
      | tee -i logs/main.log

  # others
  SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=10m FPGA_BINS="naive_simd improve_no_tcu_lut_fexp" ./run_hw.sh \
      --input generated_suites/llama3_8b_main \
      --output outputs_main_small \
      --no-power \
      --retry \
      | tee -i logs/main.log
fi

# ----------------------------------------------------------------------------
# power measure
# ----------------------------------------------------------------------------
if [[ "$target" == "power" ]]; then
  FPGA_BINS="naive_simd" BLACKBOX_TIMEOUT=30m ./run_hw.sh --input generated_suites/llama2_7b_main_power --output outputs_main_small_power \
    --no-latency \
    --no-power-auto-duration \
    --power-measure-latency \
    --power-min-interval 0.01 --power-max-interval 0.01 \
    --power-min-samples 1 \
    --retry \
    | tee -i logs/main_power.log

  FPGA_BINS="naive_simd" BLACKBOX_TIMEOUT=30m ./run_hw.sh --input generated_suites/llama3_8b_main_power --output outputs_main_small_power \
    --no-latency \
    --no-power-auto-duration \
    --power-measure-latency \
    --power-min-interval 0.01 --power-max-interval 0.01 \
    --power-min-samples 1 \
    --retry \
    | tee -i logs/main_power.log
fi

# # sgemm tcu
# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=30m FPGA_BINS="naive_simd" ./run_hw.sh \
#     --input generated_suites/main \
#     --output outputs_main \
#     --no-power \
#     --filter "app==sgemm_tcu" \
#     | tee -i logs/main.log

# # other simd
# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=30m FPGA_BINS="improve_no_tcu_lut_fexp naive_simd" ./run_hw.sh \
#     --input generated_suites/main \
#     --output outputs_main \
#     --no-power \
#     --filter "app!=sgemm_tcu" \
#     | tee -i logs/main.log


# # ----------------------------------------------------------------------------------------------------
# # ETC
# # ----------------------------------------------------------------------------------------------------
# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align ./run_hw.sh \
#     --input generated_suites/main \
#     --output outputs_temp \
#     --retry \
#     --retry-timeout-growth 2 \
#     --filter "app=softmax_layout_fused | app=softmax" \
#     | tee -i logs/main.log

# SKIP_EXISTING=1 ./run_hw.sh --input generated_suites/main_power --output outputs_main_power \
#   --no-latency --retry --retry-timeout-growth 2 \
#   --power-auto-duration --power-max-iterations 3 \
#   --filter "app==kv_cache_quant_layout_fused_w4a16" \
#   | tee -i logs/main_power.log

#   # --filter \ "app==sgemm_tcu" \

# STAGES=prefill SKIP_EXISTING=1 ./run_hw.sh \
#   --input generated_suites/main_power_long \
#   --output outputs_main_power_long \
#   --no-latency --retry --retry-timeout-growth 2 \
#   --power-auto-duration --power-max-iterations 1 \
#   --filter "app==kv_cache_quant_layout_fused_w4a16"

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="naive_simd" ./run_hw.sh \
#     --input generated_suites/llama3_8b_main \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     | tee -i logs/main.log

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="improve_tcol32 naive_gemm_tcol32 improve_no_tcu_lut_fexp" ./run_hw.sh \
#     --input generated_suites/llama3_8b_main \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     | tee -i logs/main.log

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=30m FPGA_BINS="improve_tcol32 naive_gemm_tcol32" ./run_hw.sh \
#     --input generated_suites/main_all \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     --filter "(app==fpint_gemm_ffn_hw | app==fpint_gemm_ffn_hw_naive) & stage==generation" \
#     | tee -i logs/main.log

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="improve_tcol32 naive_simd" ./run_hw.sh \
#     --input generated_suites/llama3_8b_main_all \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     --filter "app==fpint_gemm_ffn_hw | app==sgemm_tcu" \
#     | tee -i logs/main.log

# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=3m FPGA_BINS="improve_tcol32 naive_simd" ./run_hw.sh \
#     --input generated_suites/llama3_8b_main_all \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     --filter "app==fpint_gemm_ffn_hw | app==sgemm_tcu" \
#     | tee -i logs/main.log


# SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align BLACKBOX_TIMEOUT=30m FPGA_BINS="improve_tcol32 naive_gemm_tcol32" ./run_hw.sh \
#     --input generated_suites/main_all \
#     --output outputs_main \
#     --retry \
#     --retry-timeout-growth 2 \
#     --no-power \
#     | tee -i logs/main.log
