#!/bin/bash

echo "Running on HW"

echo "STAGE=prefill"
STAGE=prefill ./run_naive_gemm.sh
STAGE=prefill ./run_naive_simd.sh
STAGE=prefill ./run_improve_tcol32.sh

echo "STAGE=generation"
STAGE=generation ./run_naive_gemm.sh
STAGE=generation ./run_naive_simd.sh
STAGE=generation ./run_improve_tcol32.sh