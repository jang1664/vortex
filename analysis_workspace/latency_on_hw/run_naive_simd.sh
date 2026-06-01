#!/bin/bash

set -euo pipefail

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi
WARMUP="${WARMUP:-0}"
ITERATIONS="${ITERATIONS:-1}"

"${PYTHON_BIN}" -m tools.latency_bench run \
  --build-dir ../../build \
  --fpga-bin naive_simd \
  --suite generated_suites/prefill_merged/prefill_merged_naive_simd.yaml \
  --out outputs/naive_simd \
  --warmup "${WARMUP}" --iterations "${ITERATIONS}" \
  --blackbox-arg=--threads=32 \
  --blackbox-timeout 5m \
  --skip-existing
