# make cases
./make_cases.sh --input suites/main_all --output generated_suites/main_all

# run cases
./run_hw.sh \
    --input generated_suites/main_all \
    --output outputs_main \
    --retry \
    --retry-timeout-growth 2 \
    | tee -i logs/main.log

./run_hw.sh \
    --input generated_suites/main_all \
    --output outputs_main \
    --retry \
    --retry-timeout-growth 2 \
    --filter "kind=gemm & app!=sgemm_tcu" \
    | tee -i logs/main.log


# 실험 logging
# V1
- ACC MEM 가지고 있는 C3하고 fp16 없는 C4로 실험한 것 -> outputs_*_main folder를 사용.

# V2
- ACC MEM 가지고 있는 C3하고 95MHz new C4 -> outputs_*_main.new_c4
- 실험 완료인듯함.
- hadamard랑 eladd 추가 최적화. prefill만 다시 돌리는 중.

# V3
- C3_v3, C4_v3 사용.