source configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh
CONFIGS+=" -DGEMM_NAIVE_PSUM_READ_SLOTS=32 -DGEMM_NAIVE_PSUM_RESPONSE_SLOTS=32"
export CONFIGS
