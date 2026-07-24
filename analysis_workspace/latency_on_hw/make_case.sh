#!/bin/bash

target=$1

set -euo pipefail

# Separate prefill and generation configs for latency
if [[ "$target" == "full" ]]; then
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main_full \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-batches 1,2,4 \
    --generation-seq-lens 1024,2048,4096,8192,16384,32768

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main_full \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-batches 1,2,4 \
    --generation-seq-lens 1024,2048,4096,8192,16384,32768
else
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 32768 \
    --generation-batches 4 \
    --generation-seq-lens 32768

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 32768 \
    --generation-batches 1,2,4 \
    --generation-seq-lens 32768
fi
