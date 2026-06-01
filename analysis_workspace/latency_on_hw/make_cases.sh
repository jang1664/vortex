#!/bin/bash

set -euo pipefail

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
    PYTHON_BIN="python3"
fi

clean_suite_dir() {
    local out_dir="$1"
    mkdir -p "${out_dir}"
    find "${out_dir}" -maxdepth 1 -type f -name '*.yaml' -delete
}

generate_suite() {
    local suite="$1"
    local out_dir="$2"
    clean_suite_dir "${out_dir}"
    "${PYTHON_BIN}" -m tools.latency_bench generate-suites --suite "${suite}" --out "${out_dir}" --overwrite
}

generate_suite suites/llama2_7b_prefill_C1.yaml generated_suites/C1_prefill
generate_suite suites/llama2_7b_prefill_C2.yaml generated_suites/C2_prefill
generate_suite suites/llama2_7b_prefill_C3.yaml generated_suites/C3_prefill
generate_suite suites/llama2_7b_prefill_C4_alone.yaml generated_suites/C4_alone_prefill
generate_suite suites/llama2_7b_prefill_C4_fused.yaml generated_suites/C4_fused_prefill
generate_suite suites/llama2_7b_generation_C1.yaml generated_suites/C1_generation
generate_suite suites/llama2_7b_generation_C2.yaml generated_suites/C2_generation
generate_suite suites/llama2_7b_generation_C3.yaml generated_suites/C3_generation
generate_suite suites/llama2_7b_generation_C4_alone.yaml generated_suites/C4_alone_generation
generate_suite suites/llama2_7b_generation_C4_fused.yaml generated_suites/C4_fused_generation

clean_suite_dir generated_suites/prefill_merged
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob 'generated_suites/C1_prefill/*.yaml' \
    --suite-glob 'generated_suites/C2_prefill/*.yaml' \
    --suite-glob 'generated_suites/C3_prefill/*.yaml' \
    --suite-glob 'generated_suites/C4_alone_prefill/*.yaml' \
    --suite-glob 'generated_suites/C4_fused_prefill/*.yaml' \
    --out generated_suites/prefill_merged \
    --group-by-fpga-bin \
    --overwrite

clean_suite_dir generated_suites/generation_merged
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob 'generated_suites/C1_generation/*.yaml' \
    --suite-glob 'generated_suites/C2_generation/*.yaml' \
    --suite-glob 'generated_suites/C3_generation/*.yaml' \
    --suite-glob 'generated_suites/C4_alone_generation/*.yaml' \
    --suite-glob 'generated_suites/C4_fused_generation/*.yaml' \
    --out generated_suites/generation_merged \
    --group-by-fpga-bin \
    --overwrite
