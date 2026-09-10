# BRAM for TMEM, GEMM ACC (active and legacy), and core local memory.
# Keep the TMEM-only BRAM experiment's geometry, pipeline, and PnR settings.
source "$(dirname "${BASH_SOURCE[0]}")/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram.sh"

CONFIGS+=" -DGEMM_ACC_USE_URAM=0 -DLMEM_USE_URAM=0"

export CONFIGS
