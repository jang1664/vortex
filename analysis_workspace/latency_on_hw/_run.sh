#!/bin/bash

SOFTMAX_LAYOUT_FUSED_VARIANT=opt SOFTMAX_VARIANT=opt_align ./run_hw.sh \
    --input generated_suites/main \
    --output outputs_main \
    --retry \
    --retry-timeout-growth 2 \
    --filter "app=softmax_layout_fused | app=softmax" \
    | tee -i logs/main.log