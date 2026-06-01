#!/bin/bash

python -m tools.latency_bench generate-suites --suite suites/llama2_7b_prefill_C1.yaml --out generated_suites/C1_prefill --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_prefill_C2.yaml --out generated_suites/C2_prefill --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_prefill_C3.yaml --out generated_suites/C3_prefill --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_prefill_C4.yaml --out generated_suites/C4_prefill --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_generation_C1.yaml --out generated_suites/C1_generation --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_generation_C2.yaml --out generated_suites/C2_generation --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_generation_C3.yaml --out generated_suites/C3_generation --overwrite
python -m tools.latency_bench generate-suites --suite suites/llama2_7b_generation_C4.yaml --out generated_suites/C4_generation --overwrite

/home/jaeyongjang/.conda/envs/vortex/bin/python -m tools.latency_bench merge-suites \
    --suite-glob 'generated_suites/C*_prefill/*.yaml' \
    --out generated_suites/prefill_merged \
    --group-by-fpga-bin \
    --overwrite

/home/jaeyongjang/.conda/envs/vortex/bin/python -m tools.latency_bench merge-suites \
    --suite-glob 'generated_suites/C*_generation/*.yaml' \
    --out generated_suites/generation_merged \
    --group-by-fpga-bin \
    --overwrite
