#!/bin/bash

SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align ./run_hw.sh \
    --input generated_suites/main_all_softmax \
    --output outputs_softmax_opt_2 \
    --retry \
    --retry-timeout-growth 2 \
    --filter "app=softmax_layout_fused & shape.batch=1" \
    | tee -i logs/main.log