source ../build_fpfp_wload4/config.sh
CONFIGS="${CONFIGS/ -DGEMM_NAIVE_USE_ACC_MEM / }"
export CONFIGS
