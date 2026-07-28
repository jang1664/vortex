#!/bin/bash

set -euo pipefail

target="${1:-quick}"
decode_measurement="${2:-${DECODE_MEASUREMENT:-sampled}}"
decode_sample_interval="${3:-${DECODE_SAMPLE_INTERVAL:-32}}"

if [[ "${decode_measurement}" != "exact" && "${decode_measurement}" != "sampled" ]]; then
  echo "Usage: $0 [full|quick] [exact|sampled] [sample_interval]" >&2
  exit 1
fi

# Separate prefill and generation configs for latency
if [[ "$target" == "full" ]]; then
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-batches 1,2,4 \
    --generation-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-out-tokens 128 \
    --generation-max-seq-len 65536 \
    --decode-measurement "${decode_measurement}" \
    --decode-sample-interval "${decode_sample_interval}"

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-batches 1,2,4 \
    --generation-seq-lens 1024,2048,4096,8192,16384,32768 \
    --generation-out-tokens 128 \
    --generation-max-seq-len 65536 \
    --decode-measurement "${decode_measurement}" \
    --decode-sample-interval "${decode_sample_interval}"
else
  ./make_cases.sh \
    --input suites/llama2_7b \
    --output generated_suites/llama2_7b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024 \
    --generation-batches 1 \
    --generation-seq-lens 1024 \
    --generation-out-tokens 128 \
    --generation-max-seq-len 65536 \
    --decode-measurement "${decode_measurement}" \
    --decode-sample-interval "${decode_sample_interval}"

  ./make_cases.sh \
    --input suites/llama3_8b \
    --output generated_suites/llama3_8b_main \
    --prefill-batches 1 \
    --prefill-seq-lens 1024 \
    --generation-batches 1 \
    --generation-seq-lens 1024 \
    --generation-out-tokens 128 \
    --generation-max-seq-len 65536 \
    --decode-measurement "${decode_measurement}" \
    --decode-sample-interval "${decode_sample_interval}"
fi
