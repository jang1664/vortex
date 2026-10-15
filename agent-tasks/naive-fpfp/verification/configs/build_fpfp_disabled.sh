source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh
CONFIGS="${CONFIGS/ -DGEMM_NAIVE / }"
CONFIGS="${CONFIGS/ -DMXU_WLOAD_NUM=4 / -DMXU_WLOAD_NUM=4 }"
CONFIGS="${CONFIGS/ -DENABLE_GEMM_ACCEL / }"
CONFIGS+=" -DDISABLE_FSDB"
export CONFIGS
