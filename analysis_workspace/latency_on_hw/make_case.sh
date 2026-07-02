#!/bin/bash

target=$1

set -euo pipefail

# Separate prefill and generation configs for latency
if [[ "$target" == "latency" ]]; then
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048 \
    --generation-batches 1,2 \
    --generation-seq-lens 1024,2048

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048 \
    --generation-batches 1,2 \
    --generation-seq-lens 1024,2048
fi

if [[ "$target" == "power" ]]; then
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main_power \
    --prefill-batches 1 \
    --prefill-seq-lens 8192 \
    --generation-batches 2048 \
    --generation-seq-lens 8192

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main_power \
    --prefill-batches 1 \
    --prefill-seq-lens 8192 \
    --generation-batches 2048 \
    --generation-seq-lens 8192
fi