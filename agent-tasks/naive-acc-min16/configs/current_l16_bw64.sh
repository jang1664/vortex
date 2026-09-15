# Reproduce the ACC config before the validated FIFO4 profile was promoted.
source configs/naive_th16_tcol16_m16_L16_bigmem_all_bram.sh
CONFIGS+=" -DGEMM_NAIVE_USE_ACC_MEM"
export CONFIGS
