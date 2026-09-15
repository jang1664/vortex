# Reproduce the ACC config before the validated FIFO4 profile was promoted.
source configs/naive_th16_tcol16_m16_L32_bigmem_all_bram_D256.sh
CONFIGS+=" -DGEMM_NAIVE_USE_ACC_MEM"
export CONFIGS
