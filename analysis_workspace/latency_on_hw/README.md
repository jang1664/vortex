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