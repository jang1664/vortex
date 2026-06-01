#!/bin/bash

python -m tools.latency_bench run \
  --build-dir ../../build \
  --fpga-bin naive_simd \
  --suite generated_suites/prefill_merged/prefill_merged_naive_simd.yaml \
  --out outputs/naive_simd \
  --warmup 1 --iterations 3 \
  --blackbox-timeout 30m \
  --skip-existing