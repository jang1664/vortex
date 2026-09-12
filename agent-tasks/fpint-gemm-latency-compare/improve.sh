source configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
export CONFIGS
CONFIGS+=" -DDCACHE_NUM_BANKS=4 -DL1_MEM_PORTS=2"
export CONFIGS
