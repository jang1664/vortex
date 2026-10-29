# C4 rev8 baseline with SRAM-resident GEMM/SIMD tensor exchange.
source "$(dirname "${BASH_SOURCE[0]}")/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh"
CONFIGS+=" -DGEMM_SRAM_FUSION"
export CONFIGS
